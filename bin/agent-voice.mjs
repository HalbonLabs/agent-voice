#!/usr/bin/env node
// npx agent-voice install  (or uninstall). Runs the platform installer from
// the package directory, so npm users never clone.
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
