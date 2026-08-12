// agent-voice Stop hook (all platforms). Reads the hook payload on stdin,
// decides whether this session speaks, resolves every setting, and hands the
// slow work to a detached speaker process. Node, because it is the one
// runtime every supported agent ships, it starts in tens of milliseconds
// where PowerShell took ~1.4 s, and no agent except Claude Code has async
// hooks, so the hook path must return fast on its own (R-07).
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { spawn } from 'child_process';
import { fileURLToPath } from 'url';
import { join, dirname } from 'path';
import { getField } from '../lib/json-get.mjs';
import { extractSpokenWithIntent } from '../lib/extract-spoken.mjs';
import { kimiLastText } from '../lib/kimi-last-text.mjs';
import { transcriptLastText } from '../lib/transcript-last-text.mjs';
import { avHome, ensureStateDir, clampSid, resolveSession, engineMeta, defaultVoice } from './config.mjs';
import { collectFacts } from './facts.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

let raw = '';
process.stdin.on('data', c => raw += c).on('end', () => main(raw));

function main(payload) {
  if (!payload.trim()) return;
  const home = avHome();
  ensureStateDir(home);

  const sid = clampSid(getField(payload, 'session_id'));
  // last_assistant_message is the common case (Claude, Codex, Qwen, Goose);
  // prompt_response is Gemini's name for the same thing.
  let msg = getField(payload, 'last_assistant_message') || getField(payload, 'prompt_response');

  const s = resolveSession(sid, home);
  if (s.mode !== 'on') return;

  // Some agents put nothing in the payload. Kimi's reply is recovered from
  // its session transcript by shape; Droid (and anything similar) points at
  // a transcript_path, which the generic reader handles. Both only run when
  // the field is genuinely absent, leaving the inline-payload agents untouched.
  if (!msg.trim() && sid.startsWith('session_')) {
    msg = kimiLastText(sid, home);
  }
  if (!msg.trim()) {
    msg = transcriptLastText(getField(payload, 'transcript_path'));
  }
  if (!msg.trim()) return;

  const spoken = extractSpokenWithIntent(msg);
  if (!spoken.text) return;

  // Ground truth, computed independently of the model's self-report (P2).
  // Facts first, deterministic and always true; the model supplies only the
  // narrative clause; a contradiction is called out ahead of both.
  const grounded = collectFacts(sid, {
    cwd: getField(payload, 'cwd'),
    transcript_path: getField(payload, 'transcript_path'),
  }, home, spoken.text, spoken.intent);

  let intent = spoken.intent;
  // Derive intent from facts where they disagree with the model's own label:
  // red tests plus a "done" claim is a failure whatever the tag says (P3-1).
  if (grounded.contradiction && intent === 'done') intent = 'failed';
  if (!grounded.contradiction && intent === 'done'
      && grounded.facts.tests && grounded.facts.tests.status === 'fail') intent = 'failed';

  const text = [grounded.contradiction, grounded.sentence, spoken.text]
    .filter(Boolean).join(' ');

  const p = s.paths;

  // The previous turn's speaker PID rides in the job; the child does the
  // identity-checked kill (R-04). The check costs ~0.5 s on Windows via CIM,
  // which belongs in the detached child, not in the path the agent waits on.
  let prevPid = '';
  if (existsSync(p.pidFile)) {
    try { prevPid = readFileSync(p.pidFile, 'utf8').split('\n')[0].trim(); } catch { /* fine */ }
  }

  const job = {
    prevPid: /^\d+$/.test(prevPid) ? Number(prevPid) : 0,
    home,
    tag: p.tag,
    text,
    intent,
    duration: grounded.facts.duration || 0,
    cwd: getField(payload, 'cwd'),
    engine: s.engine,
    voice: s.voice,
    speed: s.speed,
    model: s.cfg.eleven_model || engineMeta('elevenlabs').defaultModel,
    nativeVoice: defaultVoice('native', s.cfg),
    python: s.python,
    mp3: p.mp3,
    wav: p.wav,
    pidFile: p.pidFile,
  };
  writeFileSync(p.jobFile, JSON.stringify(job));

  const child = spawn(process.execPath, [join(HERE, 'speak.mjs'), p.jobFile], {
    detached: true,
    stdio: 'ignore',
    env: process.env,
  });
  child.unref();
  if (child.pid) writeFileSync(p.pidFile, String(child.pid));
}
