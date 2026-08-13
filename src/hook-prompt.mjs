// agent-voice UserPromptSubmit hook (all platforms).
//   1. Intercepts the in-session `voice ...` commands via src/commands.mjs.
//   2. Otherwise injects the <spoken> summary instruction when voice is active.
import { writeFileSync, appendFileSync, existsSync, readdirSync, statSync, unlinkSync } from 'fs';
import { join } from 'path';
import { spawn } from 'child_process';
import { getField } from '../lib/json-get.mjs';
import {
  avHome, ensureStateDir, clampSid, sessionMode, readConfig, resolveSession, rootDir,
  voiceStyle, stylesData, humanizeLevel,
} from './config.mjs';
import { handleCommand } from './commands.mjs';
import { snapshotTurn } from './facts.mjs';

// The structured contract (P2-4). The intent attribute drives the earcon and
// the silence policy; forbidding the model from reporting metrics stops it
// inventing numbers, since the facts are measured independently (P2-1) and
// spoken first. The writing rules in the middle come from the selected style
// (voice style: plain by default), so the same skeleton can ask for anything
// from "short everyday words, delta only" to a fuller picture.
// Delivery texture, layered over any style. These are spoken words, not
// audio tags: a bracketed tag would be read aloud on most engines. The caps
// matter: one hesitation is human, three is a nervous robot.
const HUMANIZE_RULES = {
  off: [],
  subtle: [
    'Deliver it like unscripted speech: one brief hesitation is welcome where',
    "a person would genuinely pause to think, written as 'um,' or 'hmm,' or a",
    'beat of thought written as three dots. At most one or two per summary.',
    'These are delivery, not filler: they are allowed even in the plain style.',
  ],
  chatty: [
    'Deliver it like unscripted speech: a brief hesitation where a person',
    "would pause to think, written as 'um,' or 'hmm,' or three dots for a beat",
    "of thought, and the odd natural opener like 'right,' or 'oh,'. If",
    "something genuinely amused you, a half-laugh written as 'heh' is fine.",
    'At most two or three touches per summary, and never forced.',
    'These are delivery, not filler: they are allowed even in the plain style.',
  ],
};

function buildContract(styleId, humanize) {
  const style = stylesData.styles.find(s => s.id === styleId) || stylesData.styles[0];
  return [
    'Voice mode is active. End every reply with, on its own line:',
    '<spoken intent="done|question|blocked|failed">',
    'Prose written to be heard, not read. No markdown, no code, no file paths,',
    'no lists, no symbols.',
    ...style.rules,
    'One subject per sentence: when there are several things to say, give each',
    'its own short sentence rather than one long one.',
    ...(HUMANIZE_RULES[humanize] || []),
    'Do NOT state file counts, line counts, or test results: those are measured',
    'independently and will be spoken for you. Do not claim success; say what',
    'you did. Pick the intent honestly: question if you need a decision, blocked',
    'if you cannot proceed, failed if it did not work, done otherwise.',
    '</spoken>',
    // The closing tag sits at the end of a long rule list, far from the tag it
    // closes, which is exactly the shape that gets dropped. Stating the
    // consequence works better than showing the template: the extractor now
    // salvages a short unclosed tail, but a long one is still discarded.
    'Both tags are required. Write the closing </spoken> on its own line after the words.',
  ].join('\n');
}

// --agent=<id> marks agents whose injection protocol differs from Claude
// Code's. Gemini injects ONLY via JSON stdout with a BeforeAgent event name;
// its plain stdout becomes a user-visible systemMessage instead of context.
const agentFlag = (process.argv.find(a => a.startsWith('--agent=')) || '').slice('--agent='.length);
const EVENT_NAME = agentFlag === 'gemini' ? 'BeforeAgent' : 'UserPromptSubmit';

// Per-session state files otherwise accumulate forever, one set per session
// id. A sweep of week-old files runs at most once a day, costing one readdir.
const GC_INTERVAL_MS = 24 * 3600 * 1000;
const GC_MAX_AGE_MS = 7 * 24 * 3600 * 1000;
const GC_PATTERN = /^(on|off|text|engine|speed|voice|when|style|humanize|active|turn|speak|job|say)\./;

function sweepStaleState(state) {
  const stamp = join(state, 'last-gc');
  try {
    if (existsSync(stamp) && Date.now() - statSync(stamp).mtimeMs < GC_INTERVAL_MS) return;
  } catch { /* fine */ }
  try { writeFileSync(stamp, ''); } catch { /* fine */ }
  let entries = [];
  try { entries = readdirSync(state); } catch { return; }
  for (const name of entries) {
    if (!GC_PATTERN.test(name)) continue;
    try {
      if (Date.now() - statSync(join(state, name)).mtimeMs > GC_MAX_AGE_MS) unlinkSync(join(state, name));
    } catch { /* fine */ }
  }
}

let raw = '';
process.stdin.on('data', c => raw += c).on('end', () => main(raw));

function main(payload) {
  const home = avHome();
  const state = ensureStateDir(home);
  const cfg = readConfig(home);
  sweepStaleState(state);

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
        hookEventName: EVENT_NAME,
        additionalContext: instruction,
      },
    }) + '\n');
    // Also on stderr: on exit 0 it is not surfaced to the user, only to the
    // hook log, which is where it earns its place.
    process.stderr.write(text + '\n');
    return;
  }

  if (sessionMode(sid, home) !== 'off') {
    // Remember what the tree looked like when the turn began, so the stop
    // hook can report the turn's own changes and its duration (P2-1). Also
    // mark this session as the most recently active one (P3-4).
    snapshotTurn(sid, getField(payload, 'cwd'), home);
    try { writeFileSync(join(state, `active.${sid || 'nosession'}`), String(Date.now())); } catch { /* fine */ }

    // Pre-warm the Kokoro daemon while the model thinks, so synthesis is warm
    // by the time the reply lands (P4-2). The daemon guards against
    // duplicates itself, so a spurious spawn is harmless.
    const s = resolveSession(sid, home);
    const serve = join(rootDir(home), 'kokoro_serve.py');
    if (s.engine === 'kokoro' && s.mode === 'on' && existsSync(serve)) {
      const c = spawn(s.python, [serve, s.paths.state], { detached: true, stdio: 'ignore' });
      c.unref();
    }

    const contract = buildContract(voiceStyle(sid, home).id, humanizeLevel(sid, home).level);
    if (agentFlag === 'gemini') {
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: { hookEventName: EVENT_NAME, additionalContext: contract },
      }) + '\n');
    } else {
      process.stdout.write(contract + '\n');
    }
  }
}
