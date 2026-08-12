// Phase 6: agent breadth. Registration shapes per agent, transcript
// recovery, and the Gemini injection protocol.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';
import { main, AGENTS } from '../lib/register.mjs';
import { transcriptLastText } from '../lib/transcript-last-text.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPTS = join(tmpdir(), '.agent-voice');

const fakeHome = () => mkdtempSync(join(tmpdir(), 'av-home-'));
const install = (home, providers) => main([`mode=install`, `home=${home}`, `platform=win`, `scripts=${SCRIPTS}`, `providers=${providers}`]);
const uninstall = (home, providers) => main([`mode=uninstall`, `home=${home}`, `providers=${providers}`]);

test('the agent roster is data, and covers the plan tiers', () => {
  assert.deepEqual(AGENTS.map(a => a.id), ['claude', 'codex', 'kimi', 'qwen', 'droid', 'goose', 'gemini']);
});

test('qwen registers claude-shaped hooks in ~/.qwen/settings.json', () => {
  const home = fakeHome();
  install(home, 'qwen');
  const s = JSON.parse(readFileSync(join(home, '.qwen', 'settings.json'), 'utf8'));
  assert.equal(s.hooks.UserPromptSubmit[0].hooks[0].command, 'node');
  assert.match(s.hooks.Stop[0].hooks[0].args[0], /hook-stop\.mjs$/);
  uninstall(home, 'qwen');
  assert.deepEqual(JSON.parse(readFileSync(join(home, '.qwen', 'settings.json'), 'utf8')), {});
});

test('droid registers single-string hooks in ~/.factory/hooks.json', () => {
  const home = fakeHome();
  install(home, 'droid');
  const s = JSON.parse(readFileSync(join(home, '.factory', 'hooks.json'), 'utf8'));
  const stop = s.hooks.Stop[0].hooks[0];
  assert.equal(typeof stop.command, 'string');
  assert.match(stop.command, /^node ".*hook-stop\.mjs"$/);
});

test('goose is stop-only: no prompt hook is written', () => {
  const home = fakeHome();
  install(home, 'goose');
  const p = join(home, '.agents', 'plugins', 'agent-voice', 'hooks', 'hooks.json');
  const s = JSON.parse(readFileSync(p, 'utf8'));
  assert.equal('UserPromptSubmit' in s.hooks, false);
  assert.match(s.hooks.Stop[0].hooks[0].args[0], /hook-stop\.mjs$/);
});

test('gemini uses its own event names and the agent flag', () => {
  const home = fakeHome();
  install(home, 'gemini');
  const s = JSON.parse(readFileSync(join(home, '.gemini', 'settings.json'), 'utf8'));
  assert.ok(s.hooks.BeforeAgent, 'BeforeAgent event');
  assert.ok(s.hooks.AfterAgent, 'AfterAgent event');
  assert.deepEqual(s.hooks.BeforeAgent[0].hooks[0].args.slice(-1), ['--agent=gemini']);
});

test('uninstall with no providers sweeps every agent, experimental included', () => {
  const home = fakeHome();
  install(home, 'qwen,gemini,goose');
  main([`mode=uninstall`, `home=${home}`]);
  for (const f of [['.qwen', 'settings.json'], ['.gemini', 'settings.json']]) {
    assert.deepEqual(JSON.parse(readFileSync(join(home, ...f), 'utf8')), {});
  }
});

test('generic transcript reader handles claude-style and flat shapes', () => {
  const dir = mkdtempSync(join(tmpdir(), 'av-tr-'));
  const claudeStyle = join(dir, 'c.jsonl');
  writeFileSync(claudeStyle, [
    JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'earlier' }] } }),
    JSON.stringify({ type: 'user', message: { role: 'user', content: 'question' } }),
    JSON.stringify({ type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'final <spoken>done</spoken>' }] } }),
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","te',   // truncated
  ].join('\n'));
  assert.equal(transcriptLastText(claudeStyle), 'final <spoken>done</spoken>');

  const flat = join(dir, 'f.jsonl');
  writeFileSync(flat, [
    JSON.stringify({ role: 'user', content: 'q' }),
    JSON.stringify({ role: 'assistant', content: 'flat reply' }),
  ].join('\n'));
  assert.equal(transcriptLastText(flat), 'flat reply');

  assert.equal(transcriptLastText(join(dir, 'missing.jsonl')), '');
});

test('the stop hook recovers a droid-style reply via transcript_path', () => {
  const home = fakeHome();
  mkdirSync(join(home, '.agent-voice', 'state'), { recursive: true });
  writeFileSync(join(home, '.agent-voice', 'state', 'voice-on'), '');
  const dir = mkdtempSync(join(tmpdir(), 'av-tr-'));
  const tp = join(dir, 'session.jsonl');
  writeFileSync(tp, JSON.stringify({ role: 'assistant', content: 'work done <spoken intent="done">All wired up.</spoken>' }) + '\n');
  execFileSync(process.execPath, [join(ROOT, 'src', 'hook-stop.mjs')], {
    input: JSON.stringify({ session_id: 'd1', transcript_path: tp }),
    encoding: 'utf8',
    env: { ...process.env, AGENT_VOICE_HOME: home, AGENT_VOICE_NO_AUDIO: '1' },
  });
  // The speaker records the job in dry-run mode; poll briefly for it.
  const jobPath = join(home, '.agent-voice', 'state', 'last-job.json');
  const end = Date.now() + 5000;
  while (!existsSync(jobPath) && Date.now() < end) { /* spin briefly */ }
  assert.equal(existsSync(jobPath), true, 'reply recovered and spoken');
  assert.match(JSON.parse(readFileSync(jobPath, 'utf8')).text, /All wired up\./);
});

test('gemini prompt hook injects via JSON, not plain stdout', () => {
  const home = fakeHome();
  mkdirSync(join(home, '.agent-voice', 'state'), { recursive: true });
  writeFileSync(join(home, '.agent-voice', 'state', 'voice-on'), '');
  const out = execFileSync(process.execPath, [join(ROOT, 'src', 'hook-prompt.mjs'), '--agent=gemini'], {
    input: JSON.stringify({ session_id: 'g1', prompt: 'ordinary prompt' }),
    encoding: 'utf8',
    env: { ...process.env, AGENT_VOICE_HOME: home },
  });
  const j = JSON.parse(out);
  assert.equal(j.hookSpecificOutput.hookEventName, 'BeforeAgent');
  assert.match(j.hookSpecificOutput.additionalContext, /Voice mode is active/);
});

test('gemini stop hook reads prompt_response', () => {
  const home = fakeHome();
  mkdirSync(join(home, '.agent-voice', 'state'), { recursive: true });
  writeFileSync(join(home, '.agent-voice', 'state', 'voice-on'), '');
  execFileSync(process.execPath, [join(ROOT, 'src', 'hook-stop.mjs'), '--agent=gemini'], {
    input: JSON.stringify({ session_id: 'g2', prompt_response: '<spoken intent="done">Gemini speaks.</spoken>' }),
    encoding: 'utf8',
    env: { ...process.env, AGENT_VOICE_HOME: home, AGENT_VOICE_NO_AUDIO: '1' },
  });
  const jobPath = join(home, '.agent-voice', 'state', 'last-job.json');
  const end = Date.now() + 5000;
  while (!existsSync(jobPath) && Date.now() < end) { /* spin briefly */ }
  assert.match(JSON.parse(readFileSync(jobPath, 'utf8')).text, /Gemini speaks\./);
});
