// One config reader for every hook, replacing the sed parser the shell hooks
// used and the regex parser the PowerShell hooks used. The file is data,
// never code: values are returned as strings exactly as written.
//
// Also the home of session-state resolution: which engine, voice and speed a
// session will actually use, and where each came from. The same questions are
// asked by the prompt hook (voice status), the stop hook (what to speak with),
// and the commands, so they are answered in exactly one place.

import { readFileSync, existsSync, mkdirSync } from 'fs';
import { homedir } from 'os';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const HERE = dirname(fileURLToPath(import.meta.url));

// Tests point this at a temporary home; real runs never set it.
export function avHome() {
  return process.env.AGENT_VOICE_HOME || homedir();
}

export function rootDir(home = homedir()) {
  return join(home, '.agent-voice');
}
export function stateDir(home = homedir()) {
  return join(rootDir(home), 'state');
}
export function ensureStateDir(home = homedir()) {
  const dir = stateDir(home);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

// data/ and lib/ ship next to src/ both in the repo and in the install target.
export function dataFile(name) {
  return join(HERE, '..', 'data', name);
}
export function libFile(name) {
  return join(HERE, '..', 'lib', name);
}
export const enginesData = JSON.parse(readFileSync(dataFile('engines.json'), 'utf8'));
export const ENGINE_IDS = enginesData.engines.map(e => e.id);
export const EDGE_SHORTLIST = enginesData.edgeShortlist;

export function engineMeta(id) {
  return enginesData.engines.find(e => e.id === id) || enginesData.engines.find(e => e.id === 'native');
}

// key=value, hash comments, later duplicates win (matching the old sed|tail -1).
export function readConfig(home = homedir()) {
  const path = join(rootDir(home), 'config');
  const cfg = {};
  if (!existsSync(path)) return cfg;
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = line.match(/^\s*([^#=]+?)\s*=\s*(.*)$/);
    if (m) cfg[m[1].trim()] = m[2].trim();
  }
  return cfg;
}

// The session id lands in file paths, so anything outside [A-Za-z0-9_-] is
// clamped to the shared-state id rather than allowed to traverse (R-13).
export function clampSid(sid) {
  if (!sid) return '';
  return /^[A-Za-z0-9_-]+$/.test(sid) ? sid : 'nosession';
}

export function sessionPaths(sid, home = homedir()) {
  const state = stateDir(home);
  const tag = sid || 'nosession';
  return {
    state,
    tag,
    globalOn: join(state, 'voice-on'),
    on: sid ? join(state, `on.${sid}`) : null,
    off: sid ? join(state, `off.${sid}`) : null,
    text: sid ? join(state, `text.${sid}`) : null,
    engine: sid ? join(state, `engine.${sid}`) : null,
    speed: sid ? join(state, `speed.${sid}`) : null,
    voiceFlag: (engine) => (sid ? join(state, `voice.${engine}.${sid}`) : null),
    pidFile: join(state, `speak.${tag}.pid`),
    jobFile: join(state, `job.${tag}.json`),
    mp3: join(state, `say.${tag}.mp3`),
    wav: join(state, `say.${tag}.wav`),
  };
}

function flag(path) {
  return path ? existsSync(path) : false;
}
function readFlag(path) {
  try { return readFileSync(path, 'utf8').trim(); } catch { return ''; }
}

// ON / TEXT-ONLY / OFF for a session, with the same precedence the shell
// hooks used: a per-session flag beats the global default.
export function sessionMode(sid, home = homedir()) {
  const p = sessionPaths(sid, home);
  if (sid && flag(p.text)) return 'text';
  if (sid && flag(p.on)) return 'on';
  if (flag(p.globalOn) && !(sid && flag(p.off))) return 'on';
  return 'off';
}

// The engine, voice and speed a session resolves to, each with its origin
// ('session' or 'default') so voice status can say where it came from.
export function resolveSession(sid, home = homedir()) {
  const cfg = readConfig(home);
  const p = sessionPaths(sid, home);

  const cfgEngine = cfg.engine || 'edge';
  const engineOverride = sid && flag(p.engine) ? readFlag(p.engine) : '';
  const engine = engineOverride || cfgEngine;

  const vFlag = p.voiceFlag(engine);
  const voiceOverride = sid && flag(vFlag) ? readFlag(vFlag) : '';
  const voice = voiceOverride || defaultVoice(engine, cfg);

  const speedOverride = sid && flag(p.speed) ? readFlag(p.speed) : '';
  const speed = speedOverride || String(defaultSpeed(engine, cfg));

  return {
    cfg,
    paths: p,
    engine,
    engineFrom: engineOverride ? 'session' : 'default',
    voice,
    voiceFrom: voiceOverride ? 'session' : 'default',
    speed,
    speedFrom: speedOverride ? 'session' : 'default',
    python: cfg.python_cmd || cfg.kokoro_python || defaultPython(),
    mode: sessionMode(sid, home),
  };
}

function defaultPython() {
  return process.platform === 'win32' ? 'python' : 'python3';
}

export function defaultVoice(engine, cfg) {
  switch (engine) {
    case 'kokoro': return cfg.kokoro_voice || engineMeta('kokoro').defaultVoice;
    case 'edge': return cfg.edge_voice || engineMeta('edge').defaultVoice;
    case 'elevenlabs': return cfg.eleven_voice || engineMeta('elevenlabs').defaultVoice;
    default: return cfg.native_voice || engineMeta('native').defaultVoice;
  }
}

// One speed scale, 1.0 normal; each engine converts it to its own units later.
export function defaultSpeed(engine, cfg) {
  if (cfg.voice_speed && isFinite(Number(cfg.voice_speed))) return Number(cfg.voice_speed);
  switch (engine) {
    case 'kokoro':
      return cfg.kokoro_speed && isFinite(Number(cfg.kokoro_speed)) ? Number(cfg.kokoro_speed) : engineMeta('kokoro').defaultSpeed;
    case 'edge': {
      const m = (cfg.edge_rate || '').match(/^([+-]?\d+)%$/);
      return m ? 1 + Number(m[1]) / 100 : engineMeta('edge').defaultSpeed;
    }
    case 'native': return engineMeta('native').defaultSpeed;
    default: return 1.0;
  }
}
