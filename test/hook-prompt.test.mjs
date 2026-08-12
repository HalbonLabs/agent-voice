// The prompt hook end to end: command envelope on stdout, contract injection,
// silence when off.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const HOOK = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'hook-prompt.mjs');

function fakeHome(stateFiles = {}) {
  const home = mkdtempSync(join(tmpdir(), 'av-home-'));
  mkdirSync(join(home, '.agent-voice', 'state'), { recursive: true });
  for (const [name, content] of Object.entries(stateFiles)) {
    writeFileSync(join(home, '.agent-voice', 'state', name), content);
  }
  return home;
}

function runHook(home, payloadObj) {
  return execFileSync(process.execPath, [HOOK], {
    input: typeof payloadObj === 'string' ? payloadObj : JSON.stringify(payloadObj),
    encoding: 'utf8',
    env: { ...process.env, AGENT_VOICE_HOME: home },
  });
}

test('a voice command becomes a print-verbatim instruction for the model', () => {
  const home = fakeHome();
  const out = runHook(home, { session_id: 'p1', prompt: 'voice status' });
  const j = JSON.parse(out);
  assert.equal(j.hookSpecificOutput.hookEventName, 'UserPromptSubmit');
  assert.match(j.hookSpecificOutput.additionalContext, /agent-voice: OFF/);
  assert.match(j.hookSpecificOutput.additionalContext, /Output the block below exactly/);
});

test('voice on when active injects the spoken contract on later prompts', () => {
  const home = fakeHome();
  runHook(home, { session_id: 'p2', prompt: 'voice on' });
  const out = runHook(home, { session_id: 'p2', prompt: 'fix the tests please' });
  assert.match(out, /Voice mode is active/);
  assert.match(out, /<spoken>/);
});

test('voice off means an ordinary prompt injects nothing', () => {
  const home = fakeHome();
  const out = runHook(home, { session_id: 'p3', prompt: 'just a question' });
  assert.equal(out, '');
});

test('global on injects for a session with no flags of its own', () => {
  const home = fakeHome({ 'voice-on': '' });
  const out = runHook(home, { session_id: 'p4', prompt: 'hello' });
  assert.match(out, /Voice mode is active/);
});

test('text mode still injects the summary contract', () => {
  const home = fakeHome({ 'on.p5': '', 'text.p5': '' });
  const out = runHook(home, { session_id: 'p5', prompt: 'hello' });
  assert.match(out, /Voice mode is active/);
});

test('a traversal session id is clamped, never a path', () => {
  const home = fakeHome();
  runHook(home, { session_id: '../../evil', prompt: 'voice on' });
  assert.equal(existsSync(join(home, '.agent-voice', 'state', 'on.nosession')), true);
});
