import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), '..', 'lib', 'json-get.mjs');
const run = (input, key) => execFileSync(process.execPath, [SCRIPT, key], { input, encoding: 'utf8' });

test('well-formed payload prints the field', () => {
  const payload = JSON.stringify({ session_id: 'abc-123', last_assistant_message: 'All done.' });
  assert.equal(run(payload, 'last_assistant_message'), 'All done.');
  assert.equal(run(payload, 'session_id'), 'abc-123');
});

test('non-string values are stringified', () => {
  assert.equal(run('{"stop_hook_active":true,"n":3}', 'stop_hook_active'), 'true');
  assert.equal(run('{"n":3}', 'n'), '3');
});

test('null value prints empty', () => {
  assert.equal(run('{"a":null}', 'a'), '');
});

test('missing key prints empty', () => {
  assert.equal(run('{"a":1}', 'b'), '');
});

test('BOM-prefixed input still parses (PowerShell piped stdin)', () => {
  assert.equal(run('﻿{"last_assistant_message":"hello"}', 'last_assistant_message'), 'hello');
});

test('openai/codex#23784: unterminated string is salvaged', () => {
  // Codex on Windows truncates the payload mid-string when the message has
  // non-ASCII text, so the string never closes and the object never closes.
  const raw = '{"session_id":"s1","last_assistant_message":"Fixed the café module — tests green';
  assert.equal(run(raw, 'last_assistant_message'), 'Fixed the café module — tests green');
});

test('salvage unescapes JSON escapes', () => {
  const raw = '{"m":"line one\\nline \\"two\\" \\u0041 end';
  assert.equal(run(raw, 'm'), 'line one\nline "two" A end');
});

test('salvage of a missing key prints empty', () => {
  assert.equal(run('{"a":"unterminated', 'b'), '');
});

test('BOM plus malformed payload salvages together', () => {
  const raw = '﻿{"last_assistant_message":"broken ü';
  assert.equal(run(raw, 'last_assistant_message'), 'broken ü');
});
