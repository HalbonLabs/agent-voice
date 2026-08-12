// End-to-end tests for the Node Stop hook, against a temporary home with
// AGENT_VOICE_NO_AUDIO so the speaker runs its full lifecycle silently.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const HOOK = join(ROOT, 'src', 'hook-stop.mjs');

function fakeHome(stateFiles = {}) {
  const home = mkdtempSync(join(tmpdir(), 'av-home-'));
  mkdirSync(join(home, '.agent-voice', 'state'), { recursive: true });
  for (const [name, content] of Object.entries(stateFiles)) {
    writeFileSync(join(home, '.agent-voice', 'state', name), content);
  }
  return home;
}

function runHook(home, payload) {
  execFileSync(process.execPath, [HOOK], {
    input: payload,
    encoding: 'utf8',
    env: { ...process.env, AGENT_VOICE_HOME: home, AGENT_VOICE_NO_AUDIO: '1' },
  });
}

const statePath = (home, name) => join(home, '.agent-voice', 'state', name);
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function waitGone(path, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (!existsSync(path)) return true;
    await sleep(50);
  }
  return false;
}

const payload = (sid, msg) => JSON.stringify({ session_id: sid, last_assistant_message: msg });

test('voice on: spawns a speaker, records its pid, everything cleaned up', async () => {
  const home = fakeHome({ 'voice-on': '' });
  runHook(home, payload('s1', 'reply <spoken>hello there</spoken>'));
  // The pidfile is written by the parent before it exits, so it must be
  // present or already consumed; the job file must be consumed by the child.
  assert.equal(await waitGone(statePath(home, 'speak.s1.pid')), true, 'pidfile removed after speech');
  assert.equal(existsSync(statePath(home, 'job.s1.json')), false, 'job file consumed');
});

test('voice off: no speaker, no files', () => {
  const home = fakeHome({});
  runHook(home, payload('s2', 'reply <spoken>hello</spoken>'));
  assert.equal(existsSync(statePath(home, 'job.s2.json')), false);
  assert.equal(existsSync(statePath(home, 'speak.s2.pid')), false);
});

test('text mode: summary but no audio process', () => {
  const home = fakeHome({ 'voice-on': '', 'on.s3': '', 'text.s3': '' });
  runHook(home, payload('s3', 'reply <spoken>hello</spoken>'));
  assert.equal(existsSync(statePath(home, 'job.s3.json')), false);
  assert.equal(existsSync(statePath(home, 'speak.s3.pid')), false);
});

test('no spoken block: silence', () => {
  const home = fakeHome({ 'voice-on': '' });
  runHook(home, payload('s4', 'an ordinary reply with no block'));
  assert.equal(existsSync(statePath(home, 'speak.s4.pid')), false);
});

test('session off flag beats the global on', () => {
  const home = fakeHome({ 'voice-on': '', 'off.s5': '' });
  runHook(home, payload('s5', '<spoken>should not speak</spoken>'));
  assert.equal(existsSync(statePath(home, 'speak.s5.pid')), false);
});

test('malformed codex payload still speaks via salvage', async () => {
  const home = fakeHome({ 'voice-on': '' });
  // Unterminated JSON string, the openai/codex#23784 shape.
  const raw = '{"session_id":"s6","last_assistant_message":"café fix <spoken>salvaged fine</spoken>';
  runHook(home, raw);
  assert.equal(await waitGone(statePath(home, 'speak.s6.pid')), true, 'speaker ran and cleaned up');
});

test('a foreign process whose PID sits in the pidfile survives barge-in', async () => {
  const home = fakeHome({ 'voice-on': '' });
  const victim = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 300000)'], {
    detached: true, stdio: 'ignore',
  });
  victim.unref();
  try {
    writeFileSync(statePath(home, 'speak.s7.pid'), String(victim.pid));
    runHook(home, payload('s7', '<spoken>barge in</spoken>'));
    await waitGone(statePath(home, 'speak.s7.pid'));
    let alive = true;
    try { process.kill(victim.pid, 0); } catch { alive = false; }
    assert.equal(alive, true, 'foreign process must not be killed');
  } finally {
    try { process.kill(victim.pid); } catch { /* already gone */ }
  }
});

test('no stray files are left in the state dir', async () => {
  const home = fakeHome({ 'voice-on': '' });
  runHook(home, payload('s8', '<spoken>tidy</spoken>'));
  await waitGone(statePath(home, 'speak.s8.pid'));
  // last-job.json is the deliberate dry-run record, not a stray.
  const left = readdirSync(join(home, '.agent-voice', 'state'))
    .filter(f => f !== 'voice-on' && f !== 'last-job.json');
  assert.deepEqual(left, []);
});
