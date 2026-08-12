// The detached speaker: node speak.mjs <job-file>. Spawned by hook-stop.mjs,
// which has already resolved every setting into the job file, so this process
// needs neither the payload nor the config. Its PID is what barge-in and shush
// stop; the parent records it, so there is no window where the pidfile is
// missing or stale.
import { readFileSync, writeFileSync, unlinkSync } from 'fs';
import { join, dirname } from 'path';
import { speak } from './engines.mjs';

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
  // AGENT_VOICE_NO_AUDIO short-circuits synthesis and playback while keeping
  // the full job/pidfile lifecycle observable: the tests use it, and it makes
  // a silent dry run possible on a machine where sound would be disruptive.
  // The job is recorded so tests (and debugging) can see exactly what would
  // have been spoken.
  if (process.env.AGENT_VOICE_NO_AUDIO === '1') {
    try { writeFileSync(join(dirname(job.pidFile), 'last-job.json'), JSON.stringify(job, null, 2)); } catch { /* fine */ }
  } else {
    await speak(job);
  }
} finally {
  try { unlinkSync(job.pidFile); } catch { /* shush got there first */ }
}
