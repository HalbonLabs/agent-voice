// Recover the assistant's final reply for a Kimi Code session.
//
// Claude Code and Codex both put the reply in the Stop payload's
// last_assistant_message. Kimi's Stop payload carries only hook_event_name,
// session_id, cwd and stop_hook_active, so without this the hook has nothing to
// read and every reply is silent.
//
// The session transcript is JSONL. A context.append_loop_event carrying a
// content.part event with a text part is one complete streamed assistant
// message, so the last one in the file is the reply that just finished.
//
// Usage:  node kimi-last-text.mjs <session_id> [home]
//
// This transcript format is undocumented. If Kimi changes it, this prints
// nothing and the hook stays quiet, which is the same outcome as before the
// workaround existed rather than a new failure.

import { existsSync, readdirSync, readFileSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';

const TAIL_LINES = 1500;   // the transcript grows all session; only the end matters

const sid = process.argv[2];
const home = process.argv[3] || homedir();

function findWire() {
  const root = join(home, '.kimi-code', 'sessions');
  if (!sid || !existsSync(root)) return null;
  // The workspace directory is a hash, so the session has to be searched for.
  for (const ws of readdirSync(root)) {
    const p = join(root, ws, sid, 'agents', 'main', 'wire.jsonl');
    if (existsSync(p)) return p;
  }
  return null;
}

function lastAssistantText(file) {
  let lines;
  try { lines = readFileSync(file, 'utf8').split('\n'); } catch { return ''; }
  let text = '';
  for (const line of lines.slice(-TAIL_LINES)) {
    // Cheap pre-filter, deliberately not matching exact JSON spacing.
    if (!line.includes('content.part')) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }   // truncated or partial line
    if (o?.type !== 'context.append_loop_event') continue;
    if (o?.event?.type !== 'content.part') continue;
    const part = o.event.part;
    if (part?.type === 'text' && typeof part.text === 'string' && part.text.trim()) {
      text = part.text;
    }
  }
  return text;
}

const wire = findWire();
process.stdout.write(wire ? lastAssistantText(wire) : '');
