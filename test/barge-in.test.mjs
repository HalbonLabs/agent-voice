// R-04: a pidfile is a claim, not proof. A foreign PID that happens to sit in
// a stale speak.*.pid must never be killed. POSIX-only: the scripts under test
// are the macOS ones, and the identity check (ps -o command=) runs the same on
// the Linux CI runner.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir, platform } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SHUSH = join(ROOT, 'core', 'macos', 'shush.sh');

const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };

test('shush does not kill a foreign process whose PID is in a pidfile', { skip: platform() === 'win32' }, async () => {
  const home = mkdtempSync(join(tmpdir(), 'av-home-'));
  const state = join(home, '.agent-voice', 'state');
  mkdirSync(state, { recursive: true });

  const victim = spawn('sleep', ['300'], { detached: true, stdio: 'ignore' });
  victim.unref();
  try {
    writeFileSync(join(state, 'speak.fake.pid'), String(victim.pid));
    execFileSync('bash', [SHUSH], { env: { ...process.env, HOME: home }, encoding: 'utf8' });

    assert.equal(alive(victim.pid), true, 'foreign process must survive shush');
    assert.equal(existsSync(join(state, 'speak.fake.pid')), false, 'stale pidfile is cleaned up');
  } finally {
    try { process.kill(victim.pid); } catch { /* already gone */ }
  }
});

test('shush tolerates garbage in a pidfile', { skip: platform() === 'win32' }, () => {
  const home = mkdtempSync(join(tmpdir(), 'av-home-'));
  const state = join(home, '.agent-voice', 'state');
  mkdirSync(state, { recursive: true });
  writeFileSync(join(state, 'speak.fake.pid'), 'not-a-pid; rm -rf /');
  execFileSync('bash', [SHUSH], { env: { ...process.env, HOME: home }, encoding: 'utf8' });
  assert.equal(existsSync(join(state, 'speak.fake.pid')), false);
});
