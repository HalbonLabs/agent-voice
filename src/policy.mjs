// Attention policy (P3): the failure mode of every tool in this category is
// that it talks too much and gets turned off in week two. Attention is the
// scarce resource, so it is spent deliberately: the earcon always plays (it
// carries the intent and costs half a second), and this module decides
// whether the words follow.
//
// Runs inside the detached speaker, where a slow check delays only audio,
// never the agent.
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'fs';
import { join, basename } from 'path';
import { readConfig, stateDir } from './config.mjs';

export const WHEN_MODES = ['always', 'problem', 'question', 'long', 'never'];
const PROBLEM_INTENTS = new Set(['question', 'blocked', 'failed']);
// question and failed always cut through suppression: those are the two
// where not hearing it costs you real time.
const CUT_THROUGH = new Set(['question', 'failed']);

const RATE_LIMIT_MS = 20000;    // one utterance per 20 s across all sessions
const DEDUP_WINDOW_MS = 5 * 60000;
const DEFAULT_LONG_SECS = 45;
const DEFAULT_MIN_SECS = 15;    // under this you were watching; earcon only

export function whenMode(sid, home) {
  const state = stateDir(home);
  const flag = join(state, `when.${sid || 'nosession'}`);
  try {
    const v = readFileSync(flag, 'utf8').trim();
    if (WHEN_MODES.includes(v)) return { mode: v, from: 'session' };
  } catch { /* no session override */ }
  const cfg = readConfig(home);
  if (WHEN_MODES.includes(cfg.voice_when)) return { mode: cfg.voice_when, from: 'default' };
  // 'always' when unset: existing installs keep their behaviour; fresh
  // installs are written voice_when=problem by the installer (P3-2).
  return { mode: 'always', from: 'default' };
}

const norm = t => String(t).toLowerCase().replace(/[^a-z0-9 ]/g, '').replace(/\s+/g, ' ').trim();

// decide(job, home) -> { speech, prefix, reason }
// The earcon is not decided here: it always plays, because it is the part
// that carries most of the information (P3-1).
export function decide(job, home) {
  const state = stateDir(home);
  const cfg = readConfig(home);
  const intent = job.intent || 'done';
  const duration = Number(job.duration) || 0;
  const { mode } = whenMode(job.tag, home);
  const cut = CUT_THROUGH.has(intent);

  let speech = true;
  let reason = 'policy allows';

  if (mode === 'never') { speech = false; reason = 'voice when never'; }
  else if (mode === 'question' && intent !== 'question') { speech = false; reason = 'not a question'; }
  else if (mode === 'problem' && !PROBLEM_INTENTS.has(intent)) { speech = false; reason = 'nothing wrong'; }
  else if (mode === 'long') {
    const longSecs = Number(cfg.voice_long_secs) || DEFAULT_LONG_SECS;
    if (duration < longSecs && !cut) { speech = false; reason = 'short turn'; }
  }

  // Presence: a short turn means you were probably watching it happen. Not
  // applied to 'always', which is an explicit request for everything.
  if (speech && mode !== 'always' && !cut) {
    const minSecs = cfg.voice_min_secs === undefined ? DEFAULT_MIN_SECS : Number(cfg.voice_min_secs);
    if (duration > 0 && duration < minSecs) { speech = false; reason = 'you were watching'; }
  }

  // Rate limit across every session; cut-through intents are exempt.
  if (speech && !cut && sinceLastUtterance(state) < RATE_LIMIT_MS) {
    speech = false; reason = 'rate limited';
  }

  // De-duplicate: a summary substantially identical to one spoken in the
  // last five minutes says nothing new.
  if (speech && !cut && isDuplicate(state, job.text)) {
    speech = false; reason = 'duplicate of recent utterance';
  }

  // Multi-session arbitration (P3-4): only the most recently active session
  // speaks freely; question/failed from any session cut through with the
  // project name in front, so five agents stay followable.
  let prefix = '';
  if (speech && !isMostRecentlyActive(state, job.tag)) {
    if (cut) {
      const proj = job.cwd ? basename(job.cwd) : '';
      if (proj) prefix = `In ${proj}: `;
    } else {
      speech = false; reason = 'a more recent session has the floor';
    }
  }

  return { speech, prefix, reason };
}

export function recordUtterance(home, text) {
  const state = stateDir(home);
  try { writeFileSync(join(state, 'last-utterance'), String(Date.now())); } catch { /* fine */ }
  try { writeFileSync(join(state, 'last-spoken.txt'), norm(text)); } catch { /* fine */ }
}

function sinceLastUtterance(state) {
  try { return Date.now() - Number(readFileSync(join(state, 'last-utterance'), 'utf8').trim()); }
  catch { return Infinity; }
}

function isDuplicate(state, text) {
  const p = join(state, 'last-spoken.txt');
  if (!existsSync(p)) return false;
  try {
    const age = Date.now() - Number(readFileSync(join(state, 'last-utterance'), 'utf8').trim());
    if (age > DEDUP_WINDOW_MS) return false;
    return readFileSync(p, 'utf8') === norm(text);
  } catch {
    return false;
  }
}

function isMostRecentlyActive(state, tag) {
  let entries;
  try { entries = readdirSync(state).filter(f => f.startsWith('active.')); } catch { return true; }
  if (entries.length <= 1) return true;
  let bestTag = '', bestTs = -1;
  for (const f of entries) {
    let ts = 0;
    try { ts = Number(readFileSync(join(state, f), 'utf8').trim()); } catch { continue; }
    if (ts > bestTs) { bestTs = ts; bestTag = f.slice('active.'.length); }
  }
  return bestTag === '' || bestTag === tag;
}
