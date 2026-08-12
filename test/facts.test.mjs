// Phase 2: grounded summaries. Facts come from the tree and the transcript,
// never from the model; a success claim over red tests is called out.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, appendFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';
import { snapshotTurn, collectFacts, factsSentence, contradiction } from '../src/facts.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const STOP_HOOK = join(ROOT, 'src', 'hook-stop.mjs');

function fakeHome(stateFiles = {}) {
  const home = mkdtempSync(join(tmpdir(), 'av-home-'));
  mkdirSync(join(home, '.agent-voice', 'state'), { recursive: true });
  for (const [name, content] of Object.entries(stateFiles)) {
    writeFileSync(join(home, '.agent-voice', 'state', name), content);
  }
  return home;
}

function gitRepo() {
  const repo = mkdtempSync(join(tmpdir(), 'av-repo-'));
  const g = args => execFileSync('git', args, { cwd: repo, stdio: 'ignore' });
  g(['init', '-q']);
  g(['config', 'user.email', 'test@test']);
  g(['config', 'user.name', 'test']);
  writeFileSync(join(repo, 'a.txt'), 'one\ntwo\n');
  g(['add', '.']);
  g(['commit', '-q', '-m', 'base']);
  return repo;
}

function transcriptFixture(dir, resultText, { isError = true, cmd = 'npm test' } = {}) {
  const p = join(dir, 'transcript.jsonl');
  const now = new Date().toISOString();
  const lines = [
    JSON.stringify({ type: 'assistant', timestamp: now, message: { content: [
      { type: 'tool_use', id: 't1', name: 'Bash', input: { command: cmd } }] } }),
    JSON.stringify({ type: 'user', timestamp: now, message: { content: [
      { type: 'tool_result', tool_use_id: 't1', is_error: isError, content: resultText }] } }),
    JSON.stringify({ type: 'assistant', timestamp: now, message: { content: [
      { type: 'tool_use', id: 't2', name: 'Edit', input: { file_path: '/x/y.ts' } }] } }),
  ];
  writeFileSync(p, lines.join('\n') + '\n');
  return p;
}

test('factsSentence formats files, lines, commits and test state', () => {
  assert.equal(
    factsSentence({ diff: { files: 3, insertions: 40, deletions: 20 }, tests: { status: 'fail', failed: 2, passed: 38 } }),
    '3 files, 60 lines. Tests failing, 2 of 40.');
  assert.equal(
    factsSentence({ diff: { files: 2, insertions: 10, deletions: 0, commits: 2 }, tests: { status: 'pass' } }),
    '2 commits, 2 files, 10 lines. Tests passing.');
  assert.equal(factsSentence({ tests: { status: 'pass' } }), 'Tests passing.');
  assert.equal(factsSentence({}), '');
});

test('code changed with no test run is said out loud', () => {
  assert.equal(factsSentence({ edits: 1 }), '1 edit. Tests not run.');
  assert.equal(
    factsSentence({ diff: { files: 2, insertions: 5, deletions: 0, commits: 0 } }),
    '2 files, 5 lines. Tests not run.');
});

test('contradiction fires only on a success claim over red facts', () => {
  const red = { tests: { status: 'fail' } };
  assert.match(contradiction(red, 'I have successfully implemented auth.'), /Tests failing, but the summary claims success/);
  assert.equal(contradiction(red, 'The tests are red; I need direction.'), '');
  assert.equal(contradiction({ tests: { status: 'pass' } }, 'All done and working.'), '');
  assert.equal(contradiction({}, 'Everything is complete.'), '');
});

test('negated claims and honest non-done intents never trip the alarm', () => {
  const red = { tests: { status: 'fail' } };
  // The user-reported class: honest failure wording that contains claim words.
  assert.equal(contradiction(red, 'The build is still not working.'), '');
  assert.equal(contradiction(red, "It isn't done yet; two tests are red."), '');
  assert.equal(contradiction(red, 'I could not get it working.'), '');
  // An honest intent label suppresses it regardless of wording.
  assert.equal(contradiction(red, 'I fixed it successfully.', 'failed'), '');
  assert.equal(contradiction(red, 'I fixed it successfully.', 'blocked'), '');
  // A real claim still fires.
  assert.match(contradiction(red, 'It is now working correctly.', 'done'), /claims success/);
});

test('a turn diff is the delta since the snapshot, not the whole tree', () => {
  const home = fakeHome();
  const repo = gitRepo();
  // Pre-existing working-tree change, present BEFORE the turn starts.
  appendFileSync(join(repo, 'a.txt'), 'pre-existing\n');
  snapshotTurn('t1', repo, home);
  // The turn's own work.
  writeFileSync(join(repo, 'b.txt'), 'new file\nsecond line\n');
  const { facts } = collectFacts('t1', { cwd: repo }, home, '');
  assert.ok(facts.diff, 'diff facts expected');
  assert.equal(facts.diff.files, 1, 'only the file changed during the turn');
  assert.deepEqual(facts.diff.names, ['b.txt']);
  assert.ok(facts.duration >= 0);
});

test('transcript facts: failing test run with parsed counts, edits counted', () => {
  const home = fakeHome();
  snapshotTurn('t2', '', home);
  const dir = mkdtempSync(join(tmpdir(), 'av-tr-'));
  const tp = transcriptFixture(dir, 'ℹ tests 5\nℹ pass 3\nℹ fail 2');
  const { facts, sentence } = collectFacts('t2', { transcript_path: tp }, home, '');
  assert.equal(facts.tests.status, 'fail');
  assert.equal(facts.tests.failed, 2);
  assert.equal(facts.edits, 1);
  assert.match(sentence, /Tests failing, 2 of 5\./);
});

test('committing during the turn no longer hides the work', () => {
  const home = fakeHome();
  const repo = gitRepo();
  const g = args => execFileSync('git', args, { cwd: repo, stdio: 'ignore' });
  snapshotTurn('tc', repo, home);
  // The turn edits a file AND commits it, the way a well-behaved agent works.
  writeFileSync(join(repo, 'c.txt'), 'new work\nmore work\n');
  g(['add', '.']);
  g(['commit', '-q', '-m', 'turn work']);
  const { facts, sentence } = collectFacts('tc', { cwd: repo }, home, '');
  assert.ok(facts.diff, 'committed work must still be reported');
  assert.equal(facts.diff.commits, 1);
  assert.ok(facts.diff.files >= 1, 'the committed file counts');
  assert.match(sentence, /1 commit/);
});

test('collectFacts is fail-open on garbage inputs', () => {
  const home = fakeHome();
  const r = collectFacts('t3', { cwd: '/does/not/exist', transcript_path: '/nope.jsonl' }, home, 'text');
  assert.deepEqual(r.facts, {});
  assert.equal(r.sentence, '');
  assert.equal(r.contradiction, '');
});

const sleep = ms => new Promise(r => setTimeout(r, ms));
async function waitFor(pred, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (pred()) return true; await sleep(50); }
  return false;
}

test('end to end: red tests plus a done claim speaks the contradiction first and flips intent', async () => {
  const home = fakeHome({ 'voice-on': '' });
  const dir = mkdtempSync(join(tmpdir(), 'av-tr-'));
  const tp = transcriptFixture(dir, 'Tests: 3 failed, 37 passed');
  const payload = JSON.stringify({
    session_id: 'e2e1',
    transcript_path: tp,
    last_assistant_message: 'Long reply. <spoken intent="done">I fixed the authentication flow successfully.</spoken>',
  });
  execFileSync(process.execPath, [STOP_HOOK], {
    input: payload, encoding: 'utf8',
    env: { ...process.env, AGENT_VOICE_HOME: home, AGENT_VOICE_NO_AUDIO: '1' },
  });
  const jobPath = join(home, '.agent-voice', 'state', 'last-job.json');
  assert.equal(await waitFor(() => existsSync(jobPath)), true, 'dry-run job recorded');
  const job = JSON.parse(readFileSync(jobPath, 'utf8'));
  assert.match(job.text, /^Tests failing, but the summary claims success\./);
  assert.match(job.text, /Tests failing, 3 of 40\./);
  assert.match(job.text, /I fixed the authentication flow successfully\.$/);
  assert.equal(job.intent, 'failed', 'done claim over red tests becomes failed');
});

test('end to end: an honest question keeps its intent and gets no facts prefix without data', async () => {
  const home = fakeHome({ 'voice-on': '' });
  const payload = JSON.stringify({
    session_id: 'e2e2',
    last_assistant_message: '<spoken intent="question">Should sessions use JWT or cookies?</spoken>',
  });
  execFileSync(process.execPath, [STOP_HOOK], {
    input: payload, encoding: 'utf8',
    env: { ...process.env, AGENT_VOICE_HOME: home, AGENT_VOICE_NO_AUDIO: '1' },
  });
  const jobPath = join(home, '.agent-voice', 'state', 'last-job.json');
  assert.equal(await waitFor(() => existsSync(jobPath)), true);
  const job = JSON.parse(readFileSync(jobPath, 'utf8'));
  assert.equal(job.text, 'Should sessions use JWT or cookies?');
  assert.equal(job.intent, 'question');
});
