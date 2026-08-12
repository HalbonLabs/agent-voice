// The detached speaker: node speak.mjs <job-file>. Spawned by hook-stop.mjs,
// which has already resolved every setting into the job file, so this process
// needs neither the payload nor the config. Its PID is what barge-in and shush
// stop; the parent records it, so there is no window where the pidfile is
// missing or stale.
//
// Sound order (P3/P4): the intent earcon starts immediately, because it is
// the part that carries most of the information and it costs nothing to play
// while synthesis runs. The attention policy then decides whether the words
// follow. The speaking lock ensures at most one session's words at a time:
// cut-through intents queue behind it, everything else downgrades to the
// earcon. A shush at any point ends everything via the stop marker.
import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { speak } from './engines.mjs';
import {
  decide, recordUtterance, speakingLockHeld, acquireSpeakingLock, releaseSpeakingLock,
} from './policy.mjs';
import { dataFile, readConfig, stopRequestedSince } from './config.mjs';
import { shouldNotify, shouldPush, notificationParts, pushRemote } from './notify.mjs';
import { platform } from './platform/index.mjs';

const CUT_QUEUE_MS = 30000;   // how long a question/failed waits for the floor
const sleep = ms => new Promise(r => setTimeout(r, ms));

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
job.startedAt = Date.now();

const stateDirPath = dirname(job.pidFile);

function recordDecision(decision, spoke) {
  // Always written, dry-run or live: `voice last` answers "why didn't it
  // speak?" from this.
  try {
    writeFileSync(join(stateDirPath, 'last-decision.json'), JSON.stringify({
      ts: Date.now(),
      tag: job.tag,
      intent: job.intent,
      duration: job.duration,
      reason: decision.reason,
      wantedSpeech: decision.speech,
      spoke,
      text: String(job.text).slice(0, 300),
    }, null, 2));
  } catch { /* fine */ }
}

try {
  // Cut off this session's previous turn if it is still speaking. Moved out
  // of the hook's hot path (the identity check costs ~0.5 s on Windows via
  // CIM); here it only delays this turn's own audio, and only when barging in.
  if (job.prevPid && /^\d+$/.test(String(job.prevPid))) {
    const cmdline = platform.pidCommand(Number(job.prevPid));
    if (cmdline && /speak\.mjs/.test(cmdline)) platform.killTree(Number(job.prevPid));
  }

  const decision = decide(job, job.home);
  const cfg = readConfig(job.home);
  const notifying = shouldNotify(job, cfg);
  const pushing = shouldPush(job, cfg);
  let spoke = false;

  if (process.env.AGENT_VOICE_NO_AUDIO === '1') {
    try {
      writeFileSync(join(stateDirPath, 'last-job.json'),
        JSON.stringify({ ...job, policy: decision, notify: notifying, push: pushing }, null, 2));
    } catch { /* fine */ }
    recordDecision(decision, decision.speech);
    // Push still runs in dry mode when configured: the tests point ntfy at a
    // local server, and a silent machine can still buzz a phone.
    if (pushing) await pushRemote(job, cfg);
  } else {
    let earconWait = null;
    if (!decision.silent && cfg.voice_earcons !== '0') {
      const earcon = dataFile(join('earcons', `${job.intent || 'done'}.wav`));
      if (existsSync(earcon)) earconWait = platform.playAsync(earcon, job.python);
    }
    // A problem you cannot hear (meeting, other desktop) still shows up (P5-1).
    if (notifying) {
      const { title, body } = notificationParts(job);
      platform.notify(title, body);
    }

    if (decision.speech) {
      // The floor: wait for it if this must be heard, yield it otherwise.
      let waited = 0;
      while (speakingLockHeld(job.home) && waited < (job.intent === 'question' || job.intent === 'failed' ? CUT_QUEUE_MS : 0)) {
        await sleep(250);
        waited += 250;
      }
      if (speakingLockHeld(job.home)) {
        decision.speech = false;
        decision.reason = 'another session is speaking';
      }
    }

    if (decision.speech && !stopRequestedSince(job.home, job.startedAt)) {
      acquireSpeakingLock(job.home);
      try {
        // Recorded at the START of speech, so the cross-session rate limit
        // sees an utterance in progress, not one that already finished.
        recordUtterance(job.home, job.text);
        job.text = decision.prefix + job.text;
        if (earconWait) await earconWait;   // the tone finishes before the words start
        if (!stopRequestedSince(job.home, job.startedAt)) {
          await speak(job);
          spoke = true;
        }
      } finally {
        releaseSpeakingLock(job.home);
      }
    } else if (earconWait) {
      await earconWait;
    }
    recordDecision(decision, spoke);
    if (pushing) await pushRemote(job, cfg);
  }
} finally {
  try { unlinkSync(job.pidFile); } catch { /* shush got there first */ }
}
