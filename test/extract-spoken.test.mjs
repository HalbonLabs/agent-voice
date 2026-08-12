import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'extract-spoken.mjs');
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

test('an unclosed final tag yields nothing rather than the rest of the reply', () => {
  assert.equal(run('prose <spoken>never closed'), '');
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
