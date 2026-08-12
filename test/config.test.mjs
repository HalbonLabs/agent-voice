import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  readConfig, clampSid, sessionMode, resolveSession, defaultSpeed, ENGINE_IDS,
} from '../src/config.mjs';

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

test('engine ids come from data/engines.json', () => {
  assert.deepEqual(ENGINE_IDS, ['edge', 'kokoro', 'elevenlabs', 'native']);
});

test('readConfig parses key=value with comments and duplicate-wins', () => {
  const home = fakeHome(['# a comment', 'engine=edge', 'engine=kokoro', '  voice_speed = 1.5  ']);
  const cfg = readConfig(home);
  assert.equal(cfg.engine, 'kokoro');
  assert.equal(cfg.voice_speed, '1.5');
});

test('clampSid lets UUIDs through and clamps traversal', () => {
  assert.equal(clampSid('abc-123_XYZ'), 'abc-123_XYZ');
  assert.equal(clampSid('../../etc/x'), 'nosession');
  assert.equal(clampSid('a b'), 'nosession');
  assert.equal(clampSid(''), '');
});

test('sessionMode precedence: session flags beat the global default', () => {
  const sid = 'sess1';
  assert.equal(sessionMode(sid, fakeHome([], { 'voice-on': '' })), 'on');
  assert.equal(sessionMode(sid, fakeHome([], { 'voice-on': '', [`off.${sid}`]: '' })), 'off');
  assert.equal(sessionMode(sid, fakeHome([], { [`on.${sid}`]: '' })), 'on');
  assert.equal(sessionMode(sid, fakeHome([], { [`on.${sid}`]: '', [`text.${sid}`]: '' })), 'text');
  assert.equal(sessionMode(sid, fakeHome([], {})), 'off');
  // No sid: only the global flag matters.
  assert.equal(sessionMode('', fakeHome([], { 'voice-on': '' })), 'on');
});

test('resolveSession reports overrides and their origins', () => {
  const sid = 'sess2';
  const home = fakeHome(['engine=edge', 'edge_voice=en-GB-SoniaNeural'], {
    [`engine.${sid}`]: 'kokoro',
    [`voice.kokoro.${sid}`]: 'af_heart',
    [`speed.${sid}`]: '1.75',
  });
  const s = resolveSession(sid, home);
  assert.equal(s.engine, 'kokoro');
  assert.equal(s.engineFrom, 'session');
  assert.equal(s.voice, 'af_heart');
  assert.equal(s.voiceFrom, 'session');
  assert.equal(s.speed, '1.75');
  assert.equal(s.speedFrom, 'session');
});

test('resolveSession defaults when nothing is overridden', () => {
  const home = fakeHome(['engine=edge']);
  const s = resolveSession('sess3', home);
  assert.equal(s.engine, 'edge');
  assert.equal(s.engineFrom, 'default');
  assert.equal(s.voice, 'en-US-AvaNeural');
  assert.equal(s.speed, '1.15');
});

test('a voice override is engine-scoped, so switching engines cannot leak it', () => {
  const sid = 'sess4';
  const home = fakeHome(['engine=edge'], { [`voice.kokoro.${sid}`]: 'af_heart' });
  // Session is on edge; the kokoro override must not apply.
  const s = resolveSession(sid, home);
  assert.equal(s.engine, 'edge');
  assert.equal(s.voice, 'en-US-AvaNeural');
});

test('defaultSpeed converts each engine to the one scale', () => {
  assert.equal(defaultSpeed('edge', { edge_rate: '+25%' }), 1.25);
  assert.equal(defaultSpeed('edge', { edge_rate: '-10%' }), 0.9);
  assert.equal(defaultSpeed('edge', {}), 1.15);
  assert.equal(defaultSpeed('kokoro', { kokoro_speed: '1.3' }), 1.3);
  assert.equal(defaultSpeed('native', {}), 1.2);
  assert.equal(defaultSpeed('elevenlabs', {}), 1.0);
  // voice_speed overrides everything.
  assert.equal(defaultSpeed('kokoro', { voice_speed: '2.0', kokoro_speed: '1.3' }), 2.0);
});
