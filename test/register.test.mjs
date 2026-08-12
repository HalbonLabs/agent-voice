import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { main, forms } from '../lib/register.mjs';

// Every test runs against a fresh fake home; the real one is never touched.
function fakeHome() {
  return mkdtempSync(join(tmpdir(), 'av-home-'));
}
// Must contain "agent-voice", like every real install path: that substring is
// how register.mjs recognises its own entries (fragile by design; see R-09).
const SCRIPTS = join(tmpdir(), '.agent-voice', 'core', 'windows');

function install(home, providers, platform = 'win') {
  main([`mode=install`, `home=${home}`, `platform=${platform}`, `scripts=${SCRIPTS}`, `providers=${providers}`]);
}
function uninstall(home, providers) {
  main([`mode=uninstall`, `home=${home}`, `providers=${providers}`]);
}
const readSettings = home => JSON.parse(readFileSync(join(home, '.claude', 'settings.json'), 'utf8'));

const oursIn = groups => (groups || []).filter(g => JSON.stringify(g).includes('agent-voice'));

test('install into an empty home creates both hook events', () => {
  const home = fakeHome();
  install(home, 'claude');
  const s = readSettings(home);
  assert.equal(oursIn(s.hooks.UserPromptSubmit).length, 1);
  assert.equal(oursIn(s.hooks.Stop).length, 1);
  // Both hooks are Node on every platform since the P1 core rewrite; no
  // async flag anywhere, because only Claude has one and the hook is fast.
  assert.equal(s.hooks.Stop[0].hooks[0].command, 'node');
  assert.match(s.hooks.Stop[0].hooks[0].args[0], /hook-stop\.mjs$/);
  assert.match(s.hooks.UserPromptSubmit[0].hooks[0].args[0], /hook-prompt\.mjs$/);
  assert.equal('async' in s.hooks.Stop[0].hooks[0], false);
  assert.equal(s.hooks.UserPromptSubmit[0].hooks[0].timeout, 10);
});

test('mac install registers the same node hooks', () => {
  const home = fakeHome();
  install(home, 'claude', 'mac');
  const s = readSettings(home);
  assert.equal(s.hooks.Stop[0].hooks[0].command, 'node');
  assert.match(s.hooks.Stop[0].hooks[0].args[0], /hook-stop\.mjs$/);
});

test('unrelated hooks and top-level keys survive an install', () => {
  const home = fakeHome();
  const original = {
    model: 'opus',
    env: { FOO: 'bar' },
    hooks: {
      Stop: [{ hooks: [{ type: 'command', command: 'notify-send done' }] }],
      PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: 'audit.sh' }] }],
    },
  };
  mkdirSync(join(home, '.claude'), { recursive: true });
  writeFileSync(join(home, '.claude', 'settings.json'), JSON.stringify(original, null, 2));
  install(home, 'claude');
  const s = readSettings(home);
  assert.equal(s.model, 'opus');
  assert.deepEqual(s.env, { FOO: 'bar' });
  assert.deepEqual(s.hooks.PreToolUse, original.hooks.PreToolUse);
  assert.deepEqual(s.hooks.Stop[0], original.hooks.Stop[0]);
  assert.equal(s.hooks.Stop.length, 2);
});

test('installing twice never duplicates', () => {
  const home = fakeHome();
  install(home, 'claude');
  install(home, 'claude');
  const s = readSettings(home);
  assert.equal(oursIn(s.hooks.UserPromptSubmit).length, 1);
  assert.equal(oursIn(s.hooks.Stop).length, 1);
});

test('uninstall restores a file with prior content exactly', () => {
  const home = fakeHome();
  const original = {
    model: 'opus',
    hooks: { Stop: [{ hooks: [{ type: 'command', command: 'notify-send done' }] }] },
  };
  mkdirSync(join(home, '.claude'), { recursive: true });
  writeFileSync(join(home, '.claude', 'settings.json'), JSON.stringify(original, null, 2));
  install(home, 'claude');
  uninstall(home, 'claude');
  assert.deepEqual(readSettings(home), original);
});

test('uninstall on a config that was only ours removes the hooks key entirely', () => {
  const home = fakeHome();
  install(home, 'claude');
  uninstall(home, 'claude');
  assert.deepEqual(readSettings(home), {});
});

test('an unparseable settings.json is left untouched', () => {
  const home = fakeHome();
  mkdirSync(join(home, '.claude'), { recursive: true });
  const broken = '{ "hooks": this is not json';
  writeFileSync(join(home, '.claude', 'settings.json'), broken);
  install(home, 'claude');
  assert.equal(readFileSync(join(home, '.claude', 'settings.json'), 'utf8'), broken);
});

test('codex entries use a single command string', () => {
  const home = fakeHome();
  install(home, 'codex');
  const s = JSON.parse(readFileSync(join(home, '.codex', 'hooks.json'), 'utf8'));
  const entry = s.hooks.Stop[0].hooks[0];
  assert.equal(typeof entry.command, 'string');
  assert.match(entry.command, /^node ".*hook-stop\.mjs"$/);
  assert.equal('args' in entry, false);
});

test('kimi toml block installs, reinstalls once, uninstalls clean', () => {
  const home = fakeHome();
  const tomlPath = join(home, '.kimi-code', 'config.toml');
  mkdirSync(join(home, '.kimi-code'), { recursive: true });
  const original = '[general]\ntheme = "dark"\n';
  writeFileSync(tomlPath, original);

  install(home, 'kimi');
  install(home, 'kimi');
  let txt = readFileSync(tomlPath, 'utf8');
  assert.equal((txt.match(/>>> agent-voice >>>/g) || []).length, 1);
  assert.match(txt, /theme = "dark"/);
  assert.match(txt, /event = "UserPromptSubmit"/);
  assert.match(txt, /event = "Stop"/);

  uninstall(home, 'kimi');
  txt = readFileSync(tomlPath, 'utf8');
  assert.equal(txt.includes('agent-voice'), false);
  assert.match(txt, /theme = "dark"/);
});

test('unknown provider is reported, not fatal', () => {
  const home = fakeHome();
  install(home, 'claude,doesnotexist');
  assert.equal(existsSync(join(home, '.claude', 'settings.json')), true);
});

test('a foreign hook whose path merely contains "agent-voice" survives (R-09)', () => {
  const home = fakeHome();
  const foreign = {
    hooks: {
      Stop: [{ hooks: [{ type: 'command', command: 'bash /home/u/projects/agent-voice/notify.sh' }] }],
      UserPromptSubmit: [{ hooks: [{ type: 'command', command: 'node C:\\repos\\my-agent-voice-fork\\hook.mjs' }] }],
    },
  };
  mkdirSync(join(home, '.claude'), { recursive: true });
  writeFileSync(join(home, '.claude', 'settings.json'), JSON.stringify(foreign, null, 2));
  install(home, 'claude');
  uninstall(home, 'claude');
  assert.deepEqual(readSettings(home), foreign, 'foreign hooks must never be treated as ours');
});

test('legacy unmarked entries at the real install path are still cleaned up (R-09)', () => {
  const home = fakeHome();
  // What a pre-marker version wrote: no _agentVoice key, path under ~/.agent-voice.
  const legacy = {
    hooks: {
      Stop: [{ hooks: [{ type: 'command', command: 'powershell.exe', args: ['-File', 'C:\\Users\\u\\.agent-voice\\speak.ps1'], async: true }] }],
      UserPromptSubmit: [{ hooks: [{ type: 'command', command: 'bash', args: ['/Users/u/.agent-voice/voice-context.sh'], timeout: 10 }] }],
    },
  };
  mkdirSync(join(home, '.claude'), { recursive: true });
  writeFileSync(join(home, '.claude', 'settings.json'), JSON.stringify(legacy, null, 2));
  uninstall(home, 'claude');
  assert.deepEqual(readSettings(home), {}, 'legacy entries must be removed on uninstall');
});

test('installed entries carry the explicit ownership marker (R-09)', () => {
  const home = fakeHome();
  install(home, 'claude');
  const s = readSettings(home);
  assert.match(s.hooks.Stop[0].hooks[0]._agentVoice, /^agent-voice@\d+\.\d+\.\d+$/);
  assert.match(s.hooks.UserPromptSubmit[0].hooks[0]._agentVoice, /^agent-voice@\d+\.\d+\.\d+$/);
});

test('first install backs up the pre-agent-voice original', () => {
  const home = fakeHome();
  const original = JSON.stringify({ model: 'opus' }, null, 2);
  mkdirSync(join(home, '.claude'), { recursive: true });
  writeFileSync(join(home, '.claude', 'settings.json'), original);
  install(home, 'claude');
  const bak = join(home, '.claude', 'settings.json.agent-voice.bak');
  assert.equal(readFileSync(bak, 'utf8'), original);
});

test('later runs never overwrite the backup', () => {
  const home = fakeHome();
  const original = JSON.stringify({ model: 'opus' }, null, 2);
  mkdirSync(join(home, '.claude'), { recursive: true });
  writeFileSync(join(home, '.claude', 'settings.json'), original);
  install(home, 'claude');
  install(home, 'claude');
  uninstall(home, 'claude');
  const bak = join(home, '.claude', 'settings.json.agent-voice.bak');
  assert.equal(readFileSync(bak, 'utf8'), original, 'backup must stay the pre-agent-voice original');
});

test('no backup is created when there was nothing to back up', () => {
  const home = fakeHome();
  install(home, 'claude');
  assert.equal(existsSync(join(home, '.claude', 'settings.json.agent-voice.bak')), false);
});

test('writes go through a temp file, and a stale temp file is harmless', () => {
  const home = fakeHome();
  const dir = join(home, '.claude');
  mkdirSync(dir, { recursive: true });
  // The debris a mid-write kill would leave behind.
  writeFileSync(join(dir, 'settings.json.agent-voice.tmp'), '{"half":');
  install(home, 'claude');
  const s = readSettings(home);
  assert.equal(oursIn(s.hooks.Stop).length, 1);
  // A successful write consumes the temp file via rename.
  assert.equal(existsSync(join(dir, 'settings.json.agent-voice.tmp')), false);
});

test('kimi toml writes are atomic with a backup too', () => {
  const home = fakeHome();
  const tomlPath = join(home, '.kimi-code', 'config.toml');
  mkdirSync(join(home, '.kimi-code'), { recursive: true });
  const original = '[general]\ntheme = "dark"\n';
  writeFileSync(tomlPath, original);
  install(home, 'kimi');
  assert.equal(readFileSync(tomlPath + '.agent-voice.bak', 'utf8'), original);
  assert.equal(existsSync(tomlPath + '.agent-voice.tmp'), false);
});

test('forms maps both hooks to their node entry points', () => {
  const stop = forms('speak', 'win', 'C:\\scripts');
  assert.equal(stop.argv.command, 'node');
  assert.match(stop.single, /hook-stop\.mjs"$/);
  const prompt = forms('voice-context', 'mac', '/opt/scripts');
  assert.equal(prompt.argv.command, 'node');
  assert.deepEqual(prompt.argv.args, [join('/opt/scripts', 'src', 'hook-prompt.mjs')]);
});
