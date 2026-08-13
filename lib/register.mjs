// Registers (or removes) agent-voice hooks in one or more agent configs, without
// clobbering anything else. Runs on Node, which every supported agent ships with.
//
// Usage:
//   node register.mjs mode=install home=<home> platform=win|mac scripts=<dir> providers=claude,codex,...
//   node register.mjs mode=uninstall home=<home> [providers=...]
//
// The agents themselves live in data/agents.json, not in code: each entry
// names its config file, its config style (argv-array JSON, single-string
// JSON, or Kimi's flat TOML), its event names, and whether it has a prompt
// hook at all. Adding an agent is a data change plus, at most, a payload
// field in the hooks.
//
// Idempotent: prior agent-voice entries are stripped before adding, so
// re-installing or upgrading never duplicates.

import { readFileSync, writeFileSync, existsSync, mkdirSync, copyFileSync, renameSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath, pathToFileURL } from 'url';

const HERE = dirname(fileURLToPath(import.meta.url));
const VERSION = '0.1.0';  // single source once R-21 lands; used in the ownership marker
const MARKER = 'agent-voice@' + VERSION;

export const AGENTS = JSON.parse(readFileSync(join(HERE, '..', 'data', 'agents.json'), 'utf8')).agents;

// Ownership detection. Entries we write carry an explicit _agentVoice marker.
// Entries written by versions before the marker are recognised by the exact
// installed-script shape (the install target is always ~/.agent-voice and the
// script names are ours), NOT by a raw "agent-voice" substring: that used to
// silently delete any third-party hook whose path merely contained the string,
// like a checkout at ~/projects/agent-voice (R-09).
// [\\/]+ because the test runs against JSON.stringify output, where a Windows
// backslash separator appears doubled. Covers both the shell-hook era and the
// Node-hook era paths.
const LEGACY = /\.agent-voice[\\/]+((speak|voice-context)\.(sh|ps1)|src[\\/]+hook-(prompt|stop)\.mjs)/;
const ours = g => {
  const hooks = (g && g.hooks) || [];
  if (hooks.some(h => h && h._agentVoice)) return true;
  return LEGACY.test(JSON.stringify(g));
};

// Both hooks are Node on every platform since the P1 core rewrite: node
// starts in tens of milliseconds where PowerShell took ~1.4 s, and no agent
// except Claude Code awaits hooks asynchronously. agentFlag lets an agent
// with a different injection protocol (Gemini's JSON-only stdout) identify
// itself to the hook.
const HOOK_FILES = { 'voice-context': 'hook-prompt.mjs', speak: 'hook-stop.mjs' };

export function forms(scriptBase, platform, scripts, agentFlag) {
  const p = join(scripts, 'src', HOOK_FILES[scriptBase] || scriptBase);
  const args = [p];
  if (agentFlag) args.push(`--agent=${agentFlag}`);
  return {
    argv: { command: 'node', args },
    single: `node "${p}"${agentFlag ? ` --agent=${agentFlag}` : ''}`,
  };
}

function loadJson(path) {
  if (!existsSync(path)) return {};
  try { return JSON.parse(readFileSync(path, 'utf8')); }
  catch { console.error('  SKIP ' + path + ' (could not parse; left untouched to avoid clobber)'); return null; }
}
// These are other tools' live config files, so never write them in place: a
// kill mid-write, or the agent reading at the wrong moment, must never leave a
// half-written file. First touch also keeps a one-time backup of the
// pre-agent-voice original, never overwritten by later runs.
function writeFileAtomic(path, next) {
  mkdirSync(dirname(path), { recursive: true });
  const bak = path + '.agent-voice.bak';
  if (existsSync(path) && !existsSync(bak)) {
    copyFileSync(path, bak);
    console.log('  backed up original to ' + bak);
  }
  const tmp = path + '.agent-voice.tmp';
  writeFileSync(tmp, next);
  renameSync(tmp, path);
}
function writeJson(path, obj) {
  writeFileAtomic(path, JSON.stringify(obj, null, 2) + '\n');
}

// JSON hook config shared shape; agents differ in entry form (argv vs single
// string) and in event names, both supplied by the caller.
export function mergeJson(path, mode, entries) {
  const s = loadJson(path);
  if (s === null) return false;
  s.hooks = s.hooks || {};
  const events = entries.map(e => e.event);
  for (const ev of events) {
    s.hooks[ev] = Array.isArray(s.hooks[ev]) ? s.hooks[ev] : [];
    s.hooks[ev] = s.hooks[ev].filter(g => !ours(g));
  }
  if (mode === 'install') {
    for (const e of entries) {
      s.hooks[e.event].push({ hooks: [Object.assign({ type: 'command' }, e.entry, e.extra || {}, { _agentVoice: MARKER })] });
    }
  }
  for (const ev of events) if (s.hooks[ev].length === 0) delete s.hooks[ev];
  if (Object.keys(s.hooks).length === 0) delete s.hooks;
  writeJson(path, s);
  return true;
}

export function mergeKimiToml(path, mode, upsSingle, stopSingle) {
  let txt = existsSync(path) ? readFileSync(path, 'utf8') : '';
  const begin = '# >>> agent-voice >>>';
  const end = '# <<< agent-voice <<<';
  txt = txt.replace(new RegExp('\\n?' + begin + '[\\s\\S]*?' + end + '\\n?', 'g'), '');
  if (mode === 'install') {
    const block = [
      begin,
      '[[hooks]]',
      'event = "UserPromptSubmit"',
      'command = ' + JSON.stringify(upsSingle),
      'timeout = 10',
      '',
      '[[hooks]]',
      'event = "Stop"',
      'command = ' + JSON.stringify(stopSingle),
      end,
      ''
    ].join('\n');
    txt = txt.replace(/\s*$/, '') + '\n\n' + block;
  }
  writeFileAtomic(path, txt.replace(/^\n+/, ''));
  return true;
}

function registerAgent(agent, mode, home, platform, scripts) {
  const cfgPath = join(home, ...agent.config);
  const ups = mode === 'install' && agent.promptHook !== false
    ? forms('voice-context', platform, scripts, agent.agentFlag) : null;
  const stop = mode === 'install' ? forms('speak', platform, scripts, agent.agentFlag) : null;

  if (agent.style === 'toml') {
    return mergeKimiToml(cfgPath, mode, ups && ups.single, stop && stop.single);
  }
  const entryFor = f => (agent.style === 'single' ? { command: f.single } : f.argv);
  const entries = [];
  // On uninstall the entry bodies are unused; the events list drives cleanup.
  if (agent.events.prompt && agent.promptHook !== false) {
    entries.push({ event: agent.events.prompt, entry: ups ? entryFor(ups) : {}, extra: { timeout: 10 } });
  }
  if (agent.events.stop) {
    entries.push({ event: agent.events.stop, entry: stop ? entryFor(stop) : {} });
  }
  return mergeJson(cfgPath, mode, entries);
}

export function main(rawArgs) {
  const args = Object.fromEntries(rawArgs.map(a => {
    const i = a.indexOf('=');
    return [a.slice(0, i), a.slice(i + 1)];
  }));
  const mode = args.mode || 'install';
  const home = args.home;
  const platform = args.platform;
  const scripts = args.scripts;
  let providers = (args.providers || '').split(',').map(s => s.trim()).filter(Boolean);
  // Uninstall-from-all default covers every agent, experimental included.
  if (providers.length === 0) providers = AGENTS.map(a => a.id);

  // Track partial failure so the exit code tells the truth. Without this the
  // process exits 0 whenever nothing throws — an unparseable target config is
  // only a SKIP on stderr, and an unknown provider only a log line — so the
  // installers' registration guard had nothing to catch and still printed
  // "Done." That is the exact silent-success shape the guard exists to stop.
  let failed = 0;

  for (const p of providers) {
    const agent = AGENTS.find(a => a.id === p);
    if (!agent) { console.error('  unknown provider: ' + p); failed++; continue; }
    const ok = registerAgent(agent, mode, home, platform, scripts);
    if (ok) {
      const flag = agent.experimental && mode === 'install' ? ' (experimental; see docs/AGENTS.md)' : '';
      console.log('  ' + (mode === 'install' ? 'registered' : 'removed') + ' agent-voice hooks for ' + p + flag);
    } else {
      failed++;
    }
  }

  return failed;
}

// Run only when invoked as a script, so tests can import the functions above.
// pathToFileURL, not string concatenation: on Windows argv[1] has backslashes
// and no leading slash, so a naive `'file://' + argv[1]` never matches.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // process.exitCode, not process.exit(): let stdout/stderr flush first.
  if (main(process.argv.slice(2)) > 0) process.exitCode = 1;
}
