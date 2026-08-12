// Spoken-summary styles: the writing rules the contract carries, selectable
// per session, plain by default.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';
import { voiceStyle, STYLE_IDS } from '../src/config.mjs';
import { handleCommand } from '../src/commands.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const HOOK = join(ROOT, 'src', 'hook-prompt.mjs');

function fakeHome(cfgLines = [], stateFiles = {}) {
  const home = mkdtempSync(join(tmpdir(), 'av-home-'));
  const root = join(home, '.agent-voice');
  mkdirSync(join(root, 'state'), { recursive: true });
  if (cfgLines.length) writeFileSync(join(root, 'config'), cfgLines.join('\n') + '\n');
  for (const [name, content] of Object.entries(stateFiles)) {
    writeFileSync(join(root, 'state', name), content);
  }
  return home;
}

function runHook(home, payloadObj) {
  return execFileSync(process.execPath, [HOOK], {
    input: JSON.stringify(payloadObj),
    encoding: 'utf8',
    env: { ...process.env, AGENT_VOICE_HOME: home },
  });
}

test('four styles exist and plain is the default', () => {
  assert.deepEqual(STYLE_IDS, ['plain', 'standard', 'technical', 'detailed']);
  assert.deepEqual(voiceStyle('s1', fakeHome()), { id: 'plain', from: 'default' });
});

test('session flag beats config, config beats the default', () => {
  const home = fakeHome(['voice_style=detailed'], { 'style.s1': 'technical' });
  assert.deepEqual(voiceStyle('s1', home), { id: 'technical', from: 'session' });
  assert.deepEqual(voiceStyle('other', home), { id: 'detailed', from: 'default' });
});

test('the contract carries the selected style rules', () => {
  const home = fakeHome([], { 'voice-on': '' });
  const plain = runHook(home, { session_id: 'p1', prompt: 'do something' });
  assert.match(plain, /short, everyday words/);
  assert.match(plain, /Say only the delta/);
  assert.match(plain, /One subject per sentence/);

  writeFileSync(join(home, '.agent-voice', 'state', 'style.p1'), 'detailed');
  const detailed = runHook(home, { session_id: 'p1', prompt: 'do something' });
  assert.match(detailed, /what changed, why it changed, and what happens next/);
  assert.doesNotMatch(detailed, /Say only the delta/);
});

test('voice style lists, selects by number or name, resets', () => {
  const home = fakeHome();
  const run = cmd => handleCommand(cmd, 'sess-style', home);

  let r = run('voice style');
  assert.match(r.lines[0], /how should the spoken summary be written/);
  assert.match(r.lines.find(l => l.includes('plain')), /^\s+\*/, 'default marked');

  r = run('voice style 4');
  assert.match(r.lines[0], /now written 'detailed'/);
  assert.equal(readFileSync(join(home, '.agent-voice', 'state', 'style.sess-style'), 'utf8'), 'detailed');

  r = run('voice style technical');
  assert.match(r.lines[0], /now written 'technical'/);

  r = run('voice style shakespearean');
  assert.match(r.lines[0], /unknown style/);

  r = run('voice style default');
  assert.match(r.lines[0], /override cleared/);
  assert.equal(existsSync(join(home, '.agent-voice', 'state', 'style.sess-style')), false);
});

test('voice status reports the style and its origin', () => {
  const home = fakeHome(['voice_style=technical']);
  const r = handleCommand('voice status', 'sess-style2', home);
  assert.match(r.lines.find(l => l.includes('style')), /technical \(default\)/);
});
