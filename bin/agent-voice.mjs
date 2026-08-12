#!/usr/bin/env node
// node bin/agent-voice.mjs install  (or uninstall). Runs the platform
// installer from the package directory.
//
// This was written for an `npx agent-voice install` path that does not exist:
// the bare name `agent-voice` on the public npm registry belongs to an
// unrelated project by another author, so this package has never been
// published under it and cannot be. The entry point still works from a clone,
// and would work under a scoped name if this is ever published.
import { spawnSync } from 'child_process';
import { fileURLToPath } from 'url';
import { join, dirname } from 'path';

const PKG = join(dirname(fileURLToPath(import.meta.url)), '..');
const cmd = process.argv[2] || 'install';

if (!['install', 'uninstall'].includes(cmd)) {
  console.log('usage: agent-voice [install|uninstall]');
  process.exit(2);
}

const win = process.platform === 'win32';
const script = win ? `${cmd}.ps1` : `${cmd}.sh`;
const argv = win
  ? ['powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(PKG, script)]]
  : ['bash', [join(PKG, script)]];

const r = spawnSync(argv[0], argv[1], { stdio: 'inherit' });
process.exit(r.status ?? 1);
