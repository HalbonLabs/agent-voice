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

const MARK = 'agent-voice';

// Command forms per OS. Claude uses command + args array; Codex/Kimi use a single string.
export function forms(scriptBase, platform, scripts) {
  if (platform === 'win') {
    const p = join(scripts, scriptBase + '.ps1');
    return {
      argv: { command: 'powershell.exe', args: ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', p] },
      single: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${p}"`
    };
  }
  const p = join(scripts, scriptBase + '.sh');
  return { argv: { command: 'bash', args: [p] }, single: `bash "${p}"` };
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
  const ours = g => JSON.stringify(g).includes(MARK);
  for (const ev of ['UserPromptSubmit', 'Stop']) s.hooks[ev] = s.hooks[ev].filter(g => !ours(g));
  if (mode === 'install') {
    s.hooks.UserPromptSubmit.push({ hooks: [Object.assign({ type: 'command' }, upsEntry, { timeout: 10 })] });
    s.hooks.Stop.push({ hooks: [Object.assign({ type: 'command' }, stopEntry, stopExtra || {})] });
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
    claude: () => mergeJson(join(home, '.claude', 'settings.json'), mode,
                            ups && ups.argv, stop && stop.argv, platform === 'win' ? { async: true } : {}),
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
