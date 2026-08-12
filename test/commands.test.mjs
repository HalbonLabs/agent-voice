// The 14-command surface, driven through the single Node implementation.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { handleCommand } from '../src/commands.mjs';

const SID = 'sess-cmd';

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
const statePath = (home, name) => join(home, '.agent-voice', 'state', name);
const run = (home, cmd) => handleCommand(cmd, SID, home);

test('a normal prompt is not handled', () => {
  const home = fakeHome();
  assert.equal(run(home, 'please fix the tests').handled, false);
  assert.equal(run(home, '').handled, false);
});

test('no session id: commands pass through untouched', () => {
  const home = fakeHome();
  assert.equal(handleCommand('voice on', '', home).handled, false);
});

test('voice on / text / off drive the session flags', () => {
  const home = fakeHome();
  let r = run(home, 'voice on');
  assert.equal(r.handled, true);
  assert.match(r.lines[0], /ON \(summary \+ speech\)/);
  assert.equal(existsSync(statePath(home, `on.${SID}`)), true);

  r = run(home, 'voice text');
  assert.match(r.lines[0], /TEXT-ONLY/);
  assert.equal(existsSync(statePath(home, `text.${SID}`)), true);

  r = run(home, 'voice off');
  assert.match(r.lines[0], /OFF/);
  assert.equal(existsSync(statePath(home, `on.${SID}`)), false);
  assert.equal(existsSync(statePath(home, `off.${SID}`)), true);
});

test('a leading slash and mixed case still match', () => {
  const home = fakeHome();
  assert.equal(run(home, '/Voice ON').handled, true);
  assert.equal(run(home, '  VOICE HELP  ').handled, true);
});

test('voice status reports state, engine, voice, speed with origins', () => {
  const home = fakeHome(['engine=edge'], { 'voice-on': '', [`speed.${SID}`]: '1.5' });
  const r = run(home, 'voice status');
  assert.match(r.lines[0], /ON \(global default\)/);
  assert.match(r.lines.find(l => l.includes('engine')), /edge \(default\)/);
  assert.match(r.lines.find(l => l.includes('speed')), /1\.5x \(this session/);
});

test('voice engine lists with the current one marked, then selects by number', () => {
  const home = fakeHome(['engine=edge']);
  let r = run(home, 'voice engine');
  assert.match(r.lines.find(l => l.includes('edge')), /^\s+\*/);
  r = run(home, 'voice engine 4');
  assert.match(r.lines[0], /engine for this session is now native/);
  assert.equal(readFileSync(statePath(home, `engine.${SID}`), 'utf8'), 'native');
});

test('voice engine elevenlabs warns when no key is stored', () => {
  const home = fakeHome();
  const r = run(home, 'voice engine elevenlabs');
  assert.match(r.lines[0], /no API key stored/);
});

test('voice engine rejects garbage and honours default', () => {
  const home = fakeHome([], { [`engine.${SID}`]: 'native' });
  let r = run(home, 'voice engine warp-drive');
  assert.match(r.lines[0], /unknown engine/);
  r = run(home, 'voice engine default');
  assert.match(r.lines[0], /override cleared/);
  assert.equal(existsSync(statePath(home, `engine.${SID}`)), false);
});

test('voice model on kokoro: list, pick by number, reject unknown, reset', () => {
  const home = fakeHome(['engine=kokoro']);
  let r = run(home, 'voice model');
  assert.match(r.lines[0], /Kokoro voices \(\d+ of \d+\)/);
  assert.match(r.lines[0], /model's own/);

  r = run(home, 'voice model 1');
  assert.match(r.lines[0], /voice for this session is now /);
  const flag = statePath(home, `voice.kokoro.${SID}`);
  assert.equal(existsSync(flag), true);

  r = run(home, 'voice model not-a-voice');
  assert.match(r.lines[0], /is not a Kokoro voice/);

  r = run(home, 'voice model default');
  assert.match(r.lines[0], /override cleared/);
  assert.equal(existsSync(flag), false);
});

test('voice model on edge restores shortlist casing from a lowercased command', () => {
  const home = fakeHome(['engine=edge']);
  const r = run(home, 'voice model en-gb-sonianeural');
  assert.match(r.lines[0], /en-GB-SoniaNeural/);
  assert.equal(readFileSync(statePath(home, `voice.edge.${SID}`), 'utf8'), 'en-GB-SoniaNeural');
});

test('voice speed lists, sets, bounds, resets', () => {
  const home = fakeHome();
  let r = run(home, 'voice speed');
  assert.match(r.lines[0], /speed is .*x now/);

  r = run(home, 'voice speed 1.5');
  assert.match(r.lines[0], /now 1\.5x/);
  assert.equal(readFileSync(statePath(home, `speed.${SID}`), 'utf8'), '1.5');

  r = run(home, 'voice speed 3');
  assert.match(r.lines[0], /must be a number between/);

  r = run(home, 'voice speed abc');
  assert.match(r.lines[0], /must be a number between/);

  r = run(home, 'voice speed default');
  assert.match(r.lines[0], /override cleared/);
  assert.equal(existsSync(statePath(home, `speed.${SID}`)), false);
});

test('voice preview outside kokoro refuses', () => {
  const home = fakeHome(['engine=edge']);
  const r = run(home, 'voice preview 9');
  assert.match(r.lines[0], /preview only works on Kokoro/);
});

test('voice pick outside kokoro explains itself', () => {
  const home = fakeHome(['engine=edge']);
  const r = run(home, 'voice pick');
  assert.match(r.lines[0], /picker only covers Kokoro/);
});

test('voice help covers every command', () => {
  const home = fakeHome();
  const text = run(home, 'voice help').lines.join('\n');
  for (const c of ['voice on', 'voice text', 'voice off', 'voice stop', 'voice status',
                   'voice engine', 'voice model', 'voice preview', 'voice pick',
                   'voice speed', 'voice list', 'voice help']) {
    assert.ok(text.includes(c), `help must mention ${c}`);
  }
});

test('voice stop cleans stray files and spares foreign pids', () => {
  const home = fakeHome([], {
    'speak.old.pid': '999999999',
    'say.old.wav': 'x',
    'job.old.json': '{}',
  });
  const r = run(home, 'voice stop');
  assert.match(r.lines[0], /speech stopped/);
  assert.equal(existsSync(statePath(home, 'speak.old.pid')), false);
  assert.equal(existsSync(statePath(home, 'say.old.wav')), false);
  assert.equal(existsSync(statePath(home, 'job.old.json')), false);
});
