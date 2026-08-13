import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { join, dirname } from 'node:path';

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'extract-spoken.mjs');
const SCRIPT_URL = pathToFileURL(SCRIPT).href;
const run = input => execFileSync(process.execPath, [SCRIPT], { input, encoding: 'utf8' });

test('takes the last block when the reply contains two', () => {
  const out = run('a <spoken>first</spoken> b <spoken>second</spoken> c');
  assert.equal(out, 'second');
});

test('an earlier unclosed tag does not make the match span blocks', () => {
  // The naive non-greedy match would run from the first <spoken> to the only
  // </spoken> and read "oops ... real" aloud. The (?!<spoken>) guard means the
  // matched content is just the innermost block.
  const out = run('start <spoken>oops no closing tag\nmore prose <spoken>real</spoken>');
  assert.equal(out, 'real');
});

// Forgetting the closing tag is the single most common way a turn goes silent:
// the model writes the block, ends the reply, and the strict match finds
// nothing. Recovering it is safe only while the tail is short enough to BE a
// spoken block, which is what stops the old failure mode (a tag opened mid
// reply and never closed, reading the whole reply aloud) from coming back.
test('an unclosed final tag is recovered when the tail is short enough to be a block', () => {
  assert.equal(run('prose\n\n<spoken>never closed'), 'never closed');
});

test('an unclosed final tag keeps its intent', () => {
  const out = execFileSync(process.execPath, ['-e', `
    import('${SCRIPT_URL}').then(m => {
      const r = m.extractSpokenWithIntent('prose <spoken intent="blocked">stuck on the token');
      process.stdout.write(r.intent + '|' + r.text);
    });
  `], { encoding: 'utf8' });
  assert.equal(out, 'blocked|stuck on the token');
});

test('an unclosed tag whose tail is too long stays silent', () => {
  // 401 characters of prose is not a spoken block, it is the rest of the reply.
  const tail = 'x'.repeat(401);
  assert.equal(run('prose <spoken>' + tail), '');
});

test('recovery is announced on stderr so a broken block is not invisible', () => {
  const r = spawnSync(process.execPath, [SCRIPT], { input: 'prose <spoken>never closed', encoding: 'utf8' });
  assert.equal(r.stdout, 'never closed');
  assert.match(r.stderr, /closing tag/i);
});

test('a closed block still wins over an earlier unclosed one', () => {
  assert.equal(run('<spoken>unclosed\n\n<spoken>closed</spoken>'), 'closed');
});

// The recovery must never outrank a block that was written correctly. A reply
// that closes its block and then mentions the tag again in passing still has a
// real message, and speaking the trailing fragment instead would be worse than
// the silence this recovery exists to fix: silence is visibly wrong, confidently
// speaking the wrong words is not.
test('a closed block is not shadowed by a later stray unclosed tag', () => {
  assert.equal(run('<spoken>real message</spoken> later I mention <spoken>the syntax'), 'real message');
});

// Pins the reason the tail's closing-tag check is not dead code. A bare
// "<spoken" with no ">" trips BLOCK's lookahead without being able to open a
// block itself, so nothing matches strictly and recovery is reached; the check
// then declines it because a real closing tag is present. Staying silent is
// correct here, since there is no way to tell which fragment was meant.
test('a malformed inner fragment does not get recovered as a block', () => {
  assert.equal(run('<spoken intent="done"><spoken</spoken></spoken>'), '');
});

test('empty block prints empty', () => {
  assert.equal(run('reply <spoken>   </spoken>'), '');
});

test('markdown characters are stripped and whitespace collapsed', () => {
  const out = run('<spoken>Done. `npm test` is **green**, #3 fixed.\n  See _notes_ > here | now.</spoken>');
  assert.equal(out, 'Done. npm test is green, 3 fixed. See notes here now.');
});

test('no block prints empty', () => {
  assert.equal(run('an ordinary reply with no tag at all'), '');
});

test('a leading dash is stripped so the text can never read as a flag (R-14)', () => {
  assert.equal(run('<spoken>-o /tmp/x.aiff hello</spoken>'), 'o /tmp/x.aiff hello');
  assert.equal(run('<spoken>--rate 999 hi</spoken>'), 'rate 999 hi');
  // A dash mid-text is left alone.
  assert.equal(run('<spoken>well - that worked</spoken>'), 'well - that worked');
});

test('multiline content is joined to one line', () => {
  assert.equal(run('<spoken>line one\nline two\n\nline three</spoken>'), 'line one line two line three');
});
