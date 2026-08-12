// agent-voice Stop hook (all platforms). Reads the hook payload on stdin,
// decides whether this session speaks, resolves every setting, and hands the
// slow work to a detached speaker process. Node, because it is the one
// runtime every supported agent ships, it starts in tens of milliseconds
// where PowerShell took ~1.4 s, and no agent except Claude Code has async
// hooks, so the hook path must return fast on its own (R-07).
import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs';
import { spawn } from 'child_process';
import { fileURLToPath } from 'url';
import { join, dirname } from 'path';
import { getField } from '../lib/json-get.mjs';
import { extractSpoken } from '../lib/extract-spoken.mjs';
import { kimiLastText } from '../lib/kimi-last-text.mjs';
import { avHome, ensureStateDir, clampSid, resolveSession, engineMeta, defaultVoice } from './config.mjs';
import { platform } from './platform/index.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

let raw = '';
process.stdin.on('data', c => raw += c).on('end', () => main(raw));

function main(payload) {
  if (!payload.trim()) return;
  const home = avHome();
  ensureStateDir(home);

  const sid = clampSid(getField(payload, 'session_id'));
  let msg = getField(payload, 'last_assistant_message');

  const s = resolveSession(sid, home);
  if (s.mode !== 'on') return;

  // Kimi Code's Stop payload has no last_assistant_message at all, so recover
  // the reply from its session transcript. Only runs when the field is
  // genuinely absent, which leaves Claude Code and Codex untouched.
  if (!msg.trim() && sid.startsWith('session_')) {
    msg = kimiLastText(sid, home);
  }
  if (!msg.trim()) return;

  const text = extractSpoken(msg);
  if (!text) return;

  const p = s.paths;

  // Cut off this session's previous turn if it is still speaking. A PID alone
  // is not proof: after PID reuse it can belong to an unrelated process, so
  // only signal it if its command line shows it is one of our speakers (R-04).
  if (existsSync(p.pidFile)) {
    let old = '';
    try { old = readFileSync(p.pidFile, 'utf8').split('\n')[0].trim(); } catch { /* fine */ }
    if (/^\d+$/.test(old)) {
      const cmdline = platform.pidCommand(Number(old));
      if (cmdline && /speak\.mjs/.test(cmdline)) platform.killTree(Number(old));
    }
    try { unlinkSync(p.pidFile); } catch { /* fine */ }
  }

  const job = {
    home,
    tag: p.tag,
    text,
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
