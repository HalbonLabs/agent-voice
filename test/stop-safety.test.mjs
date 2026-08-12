// The shush-restart bug and the speaking lock. The reported symptom: shush
// killed the player, the speaker read that as a playback failure, and the
// never-silent chain re-spoke the whole text in the fallback voice.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { markStopRequested, stopRequestedSince } from '../src/config.mjs';
import { stopAll } from '../src/stop.mjs';
import {
  decide, snoozeUntil, setSnooze, speakingLockHeld, acquireSpeakingLock, releaseSpeakingLock,
} from '../src/policy.mjs';

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
const statePath = (home, f) => join(home, '.agent-voice', 'state', f);

test('a stop request is visible to speakers that started before it', () => {
  const home = fakeHome();
  const t0 = Date.now() - 5;
  assert.equal(stopRequestedSince(home, t0), false);
  markStopRequested(home);
  assert.equal(stopRequestedSince(home, t0), true, 'speaker started before the shush must see it');
  assert.equal(stopRequestedSince(home, Date.now() + 1000), false, 'a future speaker is not muted by an old shush');
});

test('stopAll writes the marker before anything else and clears the lock', () => {
  const home = fakeHome([], { 'speaking.lock': JSON.stringify({ pid: process.pid, ts: Date.now() }) });
  const t0 = Date.now() - 5;
  stopAll(home);
  assert.equal(stopRequestedSince(home, t0), true);
  assert.equal(existsSync(statePath(home, 'speaking.lock')), false);
});

test('the speaking lock is held only by a live, recent process', () => {
  const home = fakeHome();
  assert.equal(speakingLockHeld(home), false);
  acquireSpeakingLock(home);
  assert.equal(speakingLockHeld(home), true, 'our own live pid holds it');
  releaseSpeakingLock(home);
  assert.equal(speakingLockHeld(home), false);
  // A dead holder never blocks anyone.
  writeFileSync(statePath(home, 'speaking.lock'), JSON.stringify({ pid: 999999999, ts: Date.now() }));
  assert.equal(speakingLockHeld(home), false);
  // A stale timestamp never blocks anyone, even from a live pid.
  writeFileSync(statePath(home, 'speaking.lock'), JSON.stringify({ pid: process.pid, ts: Date.now() - 10 * 60000 }));
  assert.equal(speakingLockHeld(home), false);
});

test('snooze silences everything, expires, and can be ended early', () => {
  const home = fakeHome();
  const job = { tag: 's1', text: 'hello', intent: 'question', duration: 60 };
  assert.equal(decide(job, home).speech, true);
  setSnooze(home, 30);
  const d = decide(job, home);
  assert.equal(d.speech, false);
  assert.equal(d.silent, true, 'earcon suppressed too');
  assert.equal(d.reason, 'snoozed');
  setSnooze(home, 0);
  assert.equal(snoozeUntil(home), 0);
  assert.equal(decide(job, home).speech, true);
  // An expired snooze is no snooze.
  writeFileSync(statePath(home, 'snooze-until'), String(Date.now() - 1000));
  assert.equal(decide(job, home).speech, true);
});
