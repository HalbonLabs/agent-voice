import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'kimi-last-text.mjs');
const run = (sid, home) => execFileSync(process.execPath, [SCRIPT, sid, home], { encoding: 'utf8' });

// Builds ~/.kimi-code/sessions/<workspace-hash>/<sid>/agents/main/wire.jsonl
function makeHome(sid, lines) {
  const home = mkdtempSync(join(tmpdir(), 'av-kimi-'));
  const dir = join(home, '.kimi-code', 'sessions', 'ws-8f2c', sid, 'agents', 'main');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'wire.jsonl'), lines.join('\n') + '\n');
  return home;
}

const textEvent = text => JSON.stringify({
  type: 'context.append_loop_event',
  event: { type: 'content.part', part: { type: 'text', text } }
});

test('last complete assistant text part wins', () => {
  const home = makeHome('sess1', [
    textEvent('first reply'),
    JSON.stringify({ type: 'context.append_loop_event', event: { type: 'tool.call', name: 'Bash' } }),
    textEvent('final reply <spoken>done</spoken>'),
  ]);
  assert.equal(run('sess1', home), 'final reply <spoken>done</spoken>');
});

test('a truncated trailing line is skipped, not fatal', () => {
  const home = makeHome('sess2', [
    textEvent('the real reply'),
    // A streaming write cut mid-line: contains the pre-filter string but is not valid JSON.
    '{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","te',
  ]);
  assert.equal(run('sess2', home), 'the real reply');
});

test('non-text and empty-text parts are skipped', () => {
  const home = makeHome('sess3', [
    textEvent('spoken-worthy reply'),
    JSON.stringify({ type: 'context.append_loop_event', event: { type: 'content.part', part: { type: 'thinking', text: 'hmm' } } }),
    JSON.stringify({ type: 'context.append_loop_event', event: { type: 'content.part', part: { type: 'text', text: '   ' } } }),
  ]);
  assert.equal(run('sess3', home), 'spoken-worthy reply');
});

test('empty transcript prints empty', () => {
  const home = makeHome('sess4', ['']);
  assert.equal(run('sess4', home), '');
});

test('unknown session prints empty', () => {
  const home = makeHome('sess5', [textEvent('x')]);
  assert.equal(run('no-such-session', home), '');
});

test('home without .kimi-code prints empty', () => {
  const home = mkdtempSync(join(tmpdir(), 'av-kimi-'));
  assert.equal(run('sess6', home), '');
});
