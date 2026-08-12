// The delivery axis: written disfluencies, off by default, capped hard.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';
import { humanizeLevel, HUMANIZE_LEVELS } from '../src/config.mjs';
import { handleCommand } from '../src/commands.mjs';

const HOOK = join(dirname(fileURLToPath(import.meta.url)), '..', 'src', 'hook-prompt.mjs');

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

test('off by default; session beats config', () => {
  assert.deepEqual(HUMANIZE_LEVELS, ['off', 'subtle', 'chatty']);
  assert.deepEqual(humanizeLevel('s1', fakeHome()), { level: 'off', from: 'default' });
  const home = fakeHome(['voice_humanize=subtle'], { 'humanize.s1': 'chatty' });
  assert.deepEqual(humanizeLevel('s1', home), { level: 'chatty', from: 'session' });
  assert.deepEqual(humanizeLevel('other', home), { level: 'subtle', from: 'default' });
});

test('the contract carries delivery rules only when enabled', () => {
  const home = fakeHome([], { 'voice-on': '' });
  const off = runHook(home, { session_id: 'h1', prompt: 'do a thing' });
  assert.doesNotMatch(off, /unscripted speech/);

  writeFileSync(join(home, '.agent-voice', 'state', 'humanize.h1'), 'subtle');
  const subtle = runHook(home, { session_id: 'h1', prompt: 'do a thing' });
  assert.match(subtle, /unscripted speech/);
  assert.match(subtle, /At most one or two/);
  assert.doesNotMatch(subtle, /heh/, 'no laughs at subtle');

  writeFileSync(join(home, '.agent-voice', 'state', 'humanize.h1'), 'chatty');
  const chatty = runHook(home, { session_id: 'h1', prompt: 'do a thing' });
  assert.match(chatty, /half-laugh written as 'heh'/);
});

test('voice humanize lists, sets, rejects garbage, resets', () => {
  const home = fakeHome();
  const run = cmd => handleCommand(cmd, 'sess-h', home);

  let r = run('voice humanize');
  assert.match(r.lines[0], /how natural should the delivery sound/);
  assert.match(r.lines.find(l => l.includes('off')), /^\s+\*/, 'off marked as current');

  r = run('voice humanize chatty');
  assert.match(r.lines[0], /now 'chatty'/);

  r = run('voice status');
  assert.ok(r.lines.some(l => /humanize chatty/.test(l)), 'status shows it when on');

  r = run('voice humanize theatrical');
  assert.match(r.lines[0], /unknown level/);

  r = run('voice humanize default');
  assert.match(r.lines[0], /override cleared/);
  assert.equal(existsSync(join(home, '.agent-voice', 'state', 'humanize.sess-h')), false);
});
