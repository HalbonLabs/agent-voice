// The detached speaker: node speak.mjs <job-file>. Spawned by hook-stop.mjs,
// which has already resolved every setting into the job file, so this process
// needs neither the payload nor the config. Its PID is what barge-in and shush
// stop; the parent records it, so there is no window where the pidfile is
// missing or stale.
//
// Sound order (P3/P4): the intent earcon starts immediately, because it is
// the part that carries most of the information and it costs nothing to play
// while synthesis runs. The attention policy then decides whether the words
// follow at all.
import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { speak } from './engines.mjs';
import { decide, recordUtterance } from './policy.mjs';
import { dataFile, readConfig } from './config.mjs';
import { platform } from './platform/index.mjs';

const jobFile = process.argv[2];
if (!jobFile) process.exit(0);

let job;
try {
  job = JSON.parse(readFileSync(jobFile, 'utf8'));
  unlinkSync(jobFile);
} catch {
  process.exit(0);
}
if (!job || !job.text) process.exit(0);

try {
  const decision = decide(job, job.home);

  // AGENT_VOICE_NO_AUDIO short-circuits synthesis and playback while keeping
  // the full job/pidfile lifecycle observable: the tests use it, and it makes
  // a silent dry run possible on a machine where sound would be disruptive.
  // The job and the policy decision are recorded so tests (and debugging) can
  // see exactly what would have been spoken and why.
  if (process.env.AGENT_VOICE_NO_AUDIO === '1') {
    try {
      writeFileSync(join(dirname(job.pidFile), 'last-job.json'),
        JSON.stringify({ ...job, policy: decision }, null, 2));
    } catch { /* fine */ }
  } else {
    const cfg = readConfig(job.home);
    let earconWait = null;
    if (cfg.voice_earcons !== '0') {
      const earcon = dataFile(join('earcons', `${job.intent || 'done'}.wav`));
      if (existsSync(earcon)) earconWait = platform.playAsync(earcon);
    }
    if (decision.speech) {
      job.text = decision.prefix + job.text;
      if (earconWait) await earconWait;   // the tone finishes before the words start
      await speak(job);
      recordUtterance(job.home, job.text);
    } else if (earconWait) {
      await earconWait;
    }
  }
} finally {
  try { unlinkSync(job.pidFile); } catch { /* shush got there first */ }
}
