// Stop all in-progress speech, every session. Used by the `voice stop`
// command and callable directly (node src/stop.mjs) for the shush wrappers
// and hotkeys.
import { readdirSync, readFileSync, unlinkSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { pathToFileURL } from 'url';
import { stateDir } from './config.mjs';
import { platform } from './platform/index.mjs';

export function stopAll(home = homedir()) {
  const state = stateDir(home);
  let entries = [];
  try { entries = readdirSync(state); } catch { return; }

  for (const name of entries) {
    if (!name.startsWith('speak.') || !name.endsWith('.pid')) continue;
    const pidFile = join(state, name);
    let pid = '';
    try { pid = readFileSync(pidFile, 'utf8').split('\n')[0].trim(); } catch { /* fine */ }
    // A PID alone is never proof: only signal it if its command line shows it
    // is one of our speakers (R-04).
    if (/^\d+$/.test(pid)) {
      const cmdline = platform.pidCommand(Number(pid));
      if (cmdline && /speak\.mjs/.test(cmdline)) platform.killTree(Number(pid));
    }
    try { unlinkSync(pidFile); } catch { /* fine */ }
  }

  // Killing a speaker skips its own cleanup, so tidy the temp audio and any
  // unread job files here rather than leaving a file per interrupted session.
  for (const name of entries) {
    if (/^say\..+\.(wav|mp3)$/.test(name) || /^job\..+\.json$/.test(name)) {
      try { unlinkSync(join(state, name)); } catch { /* fine */ }
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  stopAll(process.env.AGENT_VOICE_HOME || homedir());
  console.log('agent-voice: speech stopped.');
}
