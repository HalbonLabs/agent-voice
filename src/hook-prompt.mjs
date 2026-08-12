// agent-voice UserPromptSubmit hook (all platforms).
//   1. Intercepts the in-session `voice ...` commands via src/commands.mjs.
//   2. Otherwise injects the <spoken> summary instruction when voice is active.
import { writeFileSync, appendFileSync } from 'fs';
import { join } from 'path';
import { getField } from '../lib/json-get.mjs';
import { avHome, ensureStateDir, clampSid, sessionMode, readConfig } from './config.mjs';
import { handleCommand } from './commands.mjs';

// The contract injected each turn. P2-4 will replace this with the structured
// intent version; until then it matches what the shell hooks injected.
const CONTRACT = `Voice mode is active. End every response with a <spoken> block on its own line.
Inside it: 2 to 3 sentences of plain prose. No markdown, no code, no file paths,
no lists, no symbols. State only what changed since my last message and what
decision I need to make. If nothing needs a decision, say what you did and stop.
Written to be heard, not read. Everything above the block stays normal.`;

let raw = '';
process.stdin.on('data', c => raw += c).on('end', () => main(raw));

function main(payload) {
  const home = avHome();
  const state = ensureStateDir(home);
  const cfg = readConfig(home);

  const sid = clampSid(getField(payload, 'session_id'));
  const prompt = getField(payload, 'prompt');

  const debug = line => {
    // Off unless debug=1 is in the config: it would otherwise write part of
    // every prompt to disk, which sits badly with a tool whose whole claim is
    // that your prompts go nowhere.
    if (cfg.debug !== '1') return;
    try {
      appendFileSync(join(state, 'hook.log'),
        `${new Date().toTimeString().slice(0, 8)}  ${line}\n`);
    } catch { /* fine */ }
  };

  const { handled, lines } = handleCommand(prompt, sid, home);

  if (handled) {
    const text = lines.join('\n');
    debug(`command replied with ${text.length} chars`);
    try { writeFileSync(join(state, 'last-reply.txt'), text); } catch { /* fine */ }

    // Getting this text on screen turned out to be the hard part. stderr with
    // exit 2 is documented to show the user and works in a terminal, but the
    // VS Code extension renders none of it: not stderr, not "reason" from a
    // block decision, not "systemMessage". So the reply is handed to the model
    // as context with an instruction to print it verbatim: one cheap turn, but
    // the model's reply is the one channel every client displays. Exactly ONE
    // user-visible channel, deliberately: adding systemMessage as well doubled
    // the output on every client that renders both.
    const instruction =
      `The user typed the agent-voice command "${prompt.trim()}". The hook has already carried it out;\n` +
      'there is nothing for you to run or change. Output the block below exactly as it is,\n' +
      'inside a code fence, and write nothing else at all: no preamble, no summary, no\n' +
      '<spoken> block.\n\n' + text;
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'UserPromptSubmit',
        additionalContext: instruction,
      },
    }) + '\n');
    // Also on stderr: on exit 0 it is not surfaced to the user, only to the
    // hook log, which is where it earns its place.
    process.stderr.write(text + '\n');
    return;
  }

  if (sessionMode(sid, home) !== 'off') {
    process.stdout.write(CONTRACT + '\n');
  }
}
