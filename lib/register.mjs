// Registers (or removes) agent-voice hooks in one or more agent configs, without
// clobbering anything else. Runs on Node, which every supported agent ships with.
//
// Usage:
//   node register.mjs mode=install home=<home> platform=win|mac scripts=<dir> providers=claude,codex,kimi
//   node register.mjs mode=uninstall home=<home> [providers=claude,codex,kimi]
//
// Supported providers and where their hooks live:
//   claude -> ~/.claude/settings.json      (JSON, command + args array)
//   codex  -> ~/.codex/hooks.json          (JSON, single command string)
//   kimi   -> ~/.kimi-code/config.toml     (TOML, flat [[hooks]] entries)
//
// Idempotent: prior agent-voice entries are stripped before adding, so
// re-installing or upgrading never duplicates. The install path contains
// ".agent-voice", which is how our entries are detected.

import { readFileSync, writeFileSync, existsSync, mkdirSync, copyFileSync, renameSync } from 'fs';
import { join, dirname } from 'path';
import { pathToFileURL } from 'url';

const VERSION = '0.1.0';  // single source once R-21 lands; used in the ownership marker
const MARKER = 'agent-voice@' + VERSION;

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

// Command forms per agent config shape. Claude uses command + args array;
// Codex/Kimi use a single string. Both hooks are Node on every platform since
// the P1 core rewrite: node starts in tens of milliseconds where PowerShell
// took ~1.4 s, and no agent except Claude Code awaits hooks asynchronously.
const HOOK_FILES = { 'voice-context': 'hook-prompt.mjs', speak: 'hook-stop.mjs' };

export function forms(scriptBase, platform, scripts) {
  const p = join(scripts, 'src', HOOK_FILES[scriptBase] || scriptBase);
  return { argv: { command: 'node', args: [p] }, single: `node "${p}"` };
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

// JSON hook config shared shape (Claude and Codex differ only in entry form).
export function mergeJson(path, mode, upsEntry, stopEntry, stopExtra) {
  const s = loadJson(path);
  if (s === null) return false;
  s.hooks = s.hooks || {};
  for (const ev of ['UserPromptSubmit', 'Stop']) {
    s.hooks[ev] = Array.isArray(s.hooks[ev]) ? s.hooks[ev] : [];
  }
  for (const ev of ['UserPromptSubmit', 'Stop']) s.hooks[ev] = s.hooks[ev].filter(g => !ours(g));
  if (mode === 'install') {
    s.hooks.UserPromptSubmit.push({ hooks: [Object.assign({ type: 'command' }, upsEntry, { timeout: 10, _agentVoice: MARKER })] });
    s.hooks.Stop.push({ hooks: [Object.assign({ type: 'command' }, stopEntry, stopExtra || {}, { _agentVoice: MARKER })] });
  }
  for (const ev of ['UserPromptSubmit', 'Stop']) if (s.hooks[ev].length === 0) delete s.hooks[ev];
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
  if (providers.length === 0) providers = ['claude', 'codex', 'kimi']; // uninstall-from-all default

  const ups = mode === 'install' ? forms('voice-context', platform, scripts) : null;
  const stop = mode === 'install' ? forms('speak', platform, scripts) : null;

  const handlers = {
    // No async flag anywhere: the Node hooks return in ~100 ms, and async is
    // Claude-only, so relying on it would hide latency the other agents feel.
    claude: () => mergeJson(join(home, '.claude', 'settings.json'), mode,
                            ups && ups.argv, stop && stop.argv, {}),
    codex:  () => mergeJson(join(home, '.codex', 'hooks.json'), mode,
                            ups && { command: ups.single }, stop && { command: stop.single }, {}),
    kimi:   () => mergeKimiToml(join(home, '.kimi-code', 'config.toml'), mode,
                                ups && ups.single, stop && stop.single),
  };

  for (const p of providers) {
    if (!handlers[p]) { console.error('  unknown provider: ' + p); continue; }
    const ok = handlers[p]();
    if (ok) console.log('  ' + (mode === 'install' ? 'registered' : 'removed') + ' agent-voice hooks for ' + p);
  }
}

// Run only when invoked as a script, so tests can import the functions above.
// pathToFileURL, not string concatenation: on Windows argv[1] has backslashes
// and no leading slash, so a naive `'file://' + argv[1]` never matches.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2));
}
