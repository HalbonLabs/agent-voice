// macOS platform layer: play a file, speak with the native voice, identify and
// stop processes. Everything engine-shaped lives above this in src/engines.
import { execFileSync, spawnSync } from 'child_process';

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
