// Phase 3: the attention policy. The earcon always plays; these tests pin
// down when the words follow.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { decide, recordUtterance, whenMode } from '../src/policy.mjs';

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

const job = (over = {}) => ({ tag: 's1', text: 'the summary', intent: 'done', duration: 60, cwd: '/w/checkout-api', ...over });

test('when unset defaults to always, and session flag beats config', () => {
  const home = fakeHome(['voice_when=problem'], { 'when.s1': 'never' });
  assert.deepEqual(whenMode('s1', home), { mode: 'never', from: 'session' });
  assert.deepEqual(whenMode('other', home), { mode: 'problem', from: 'default' });
  assert.deepEqual(whenMode('x', fakeHome()), { mode: 'always', from: 'default' });
});

test('always speaks on a done turn', () => {
  const home = fakeHome();
  assert.equal(decide(job(), home).speech, true);
});

test('problem stays silent through done and speaks on the problems', () => {
  const home = fakeHome(['voice_when=problem']);
  assert.equal(decide(job({ intent: 'done' }), home).speech, false);
  assert.equal(decide(job({ intent: 'question' }), home).speech, true);
  assert.equal(decide(job({ intent: 'blocked' }), home).speech, true);
  assert.equal(decide(job({ intent: 'failed' }), home).speech, true);
});

test('question mode speaks only on questions', () => {
  const home = fakeHome(['voice_when=question']);
  assert.equal(decide(job({ intent: 'failed' }), home).speech, false);
  assert.equal(decide(job({ intent: 'question' }), home).speech, true);
});

test('long mode gates on duration but question and failed cut through', () => {
  const home = fakeHome(['voice_when=long']);
  assert.equal(decide(job({ duration: 20 }), home).speech, false);
  assert.equal(decide(job({ duration: 90 }), home).speech, true);
  assert.equal(decide(job({ duration: 5, intent: 'question' }), home).speech, true);
});

test('never means earcon only', () => {
  const home = fakeHome(['voice_when=never']);
  const d = decide(job({ intent: 'question' }), home);
  assert.equal(d.speech, false);
});

test('a short turn under problem policy is treated as watched', () => {
  const home = fakeHome(['voice_when=problem']);
  assert.equal(decide(job({ intent: 'blocked', duration: 5 }), home).speech, false);
  // But a question still cuts through.
  assert.equal(decide(job({ intent: 'question', duration: 5 }), home).speech, true);
});

test('rate limit: a second utterance within 20 s is dropped unless it cuts through', () => {
  const home = fakeHome();
  recordUtterance(home, 'first thing spoken');
  assert.equal(decide(job({ text: 'second thing' }), home).speech, false);
  assert.equal(decide(job({ text: 'urgent', intent: 'failed' }), home).speech, true);
});

test('an identical summary within five minutes is not repeated', () => {
  const home = fakeHome([], { 'last-utterance': String(Date.now() - 30000) });
  writeFileSync(join(home, '.agent-voice', 'state', 'last-spoken.txt'), 'the summary');
  assert.equal(decide(job({ text: 'The summary!' }), home).speech, false, 'normalised match');
  assert.equal(decide(job({ text: 'something different' }), home).speech, true);
});

test('only the most recently active session speaks freely; failed cuts through with a prefix', () => {
  const now = Date.now();
  const home = fakeHome([], {
    'active.s1': String(now - 60000),
    'active.s2': String(now),
  });
  assert.equal(decide(job({ tag: 's1' }), home).speech, false, 'older session yields the floor');
  assert.equal(decide(job({ tag: 's2' }), home).speech, true, 'newest session speaks');
  const d = decide(job({ tag: 's1', intent: 'failed' }), home);
  assert.equal(d.speech, true);
  assert.equal(d.prefix, 'In checkout-api: ');
});
