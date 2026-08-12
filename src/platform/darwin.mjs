// macOS platform layer: play a file, speak with the native voice, open the
// voice picker, identify and stop processes. Everything engine-shaped lives
// above this in src/engines.
import { execFileSync, spawnSync, spawn } from 'child_process';
import { join } from 'path';

export function play(file) {
  const r = spawnSync('afplay', [file], { stdio: 'ignore' });
  return r.status === 0;
}

// say takes words per minute; its default is about 175.
export function speakNative(text, { speed, voice } = {}) {
  const args = [];
  if (speed && isFinite(Number(speed))) args.push('-r', String(Math.round(175 * Number(speed))));
  if (voice && voice !== 'system default') args.push('-v', voice);
  // -- terminates option parsing: the text is model output (R-14).
  args.push('--', text);
  const r = spawnSync('say', args, { stdio: 'ignore' });
  return r.status === 0;
}

// The command line a PID is running, or '' if it is gone. A PID alone is never
// proof of identity (R-04).
export function pidCommand(pid) {
  try {
    return execFileSync('ps', ['-p', String(pid), '-o', 'command='], { encoding: 'utf8' }).trim();
  } catch {
    return '';
  }
}

// Kill a speak child and its players. Children first: killing only the parent
// leaves afplay talking.
export function killTree(pid) {
  spawnSync('pkill', ['-P', String(pid)], { stdio: 'ignore' });
  try { process.kill(pid); } catch { /* already gone */ }
}

// The picker needs its own window because the hook runs non-interactively
// with stdin carrying the JSON payload, so it has no keyboard to read. The
// sid is clamped to [A-Za-z0-9_-] before it reaches this string (R-13).
export function openPicker(root, sid, engine) {
  const script = join(root, 'pick-voice.sh');
  const r = spawnSync('osascript',
    ['-e', `tell application "Terminal" to do script "bash '${script}' --session '${sid}' '${engine}'"`],
    { stdio: 'ignore' });
  return r.status === 0;
}

// Backgrounded so the hook returns at once rather than holding up the prompt
// while audio plays.
export function previewVoice(root, voiceId) {
  const c = spawn('bash', [join(root, 'pick-voice.sh'), '--preview', voiceId], {
    detached: true, stdio: 'ignore', env: { ...process.env, ROOT: root },
  });
  c.unref();
}
