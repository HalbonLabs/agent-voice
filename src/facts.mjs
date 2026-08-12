// Ground truth about the turn that just ended, computed independently of
// anything the model said (ENHANCEMENT_PLAN P2-1). The model's self-report is
// the weakest signal in the system: it says "successfully implemented" while
// the test suite is red. These collectors read the git tree and the
// transcript instead, and the contradiction check (P2-3) says so out loud
// when the two disagree.
//
// Every collector is fail-open: any error, missing input, or blown budget
// drops that fact and the turn still speaks. Ground truth is an enhancement,
// never a dependency.
import { spawnSync } from 'child_process';
import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs';
import { join, basename } from 'path';
import { stateDir } from './config.mjs';

const GIT_BUDGET_MS = 300;          // per git call; a hung git never delays speech
const TRANSCRIPT_TAIL = 4000;       // lines; a turn does not need more history

const TEST_RUNNERS = /\b(jest|vitest|pytest|go test|cargo test|npm test|pnpm test|yarn test|dotnet test|node --test|rspec|phpunit)\b/;
const BUILD_TOOLS = /\b(tsc|next build|cargo build|go build|dotnet build|npm run build|pnpm build|vite build|webpack|make)\b/;
// Narrow and high-precision: a false contradiction alarm destroys trust
// faster than a missed one.
const SUCCESS_CLAIMS = /\b(fixed|working|passing|done|complete|completed|successfully|all tests pass)\b/i;

function git(cwd, args) {
  try {
    const r = spawnSync('git', args, { cwd, encoding: 'utf8', timeout: GIT_BUDGET_MS, stdio: ['ignore', 'pipe', 'ignore'] });
    if (r.status !== 0) return null;
    return r.stdout;
  } catch {
    return null;
  }
}

// file -> [insertions, deletions] for the working tree right now.
function numstat(cwd) {
  const out = git(cwd, ['diff', '--numstat', 'HEAD']);
  if (out == null) return null;
  const map = {};
  for (const line of out.split('\n')) {
    const m = line.match(/^(\d+|-)\t(\d+|-)\t(.+)$/);
    if (m) map[m[3]] = [m[1] === '-' ? 0 : Number(m[1]), m[2] === '-' ? 0 : Number(m[2])];
  }
  // Untracked files count as all-insertions.
  const un = git(cwd, ['ls-files', '--others', '--exclude-standard']);
  if (un) for (const f of un.split('\n').filter(Boolean)) if (!map[f]) map[f] = [-1, 0];
  return map;
}

// Called by the prompt hook: remember what the tree looked like when the turn
// began, so the stop hook can report the turn's own changes, not the whole
// working tree's.
export function snapshotTurn(sid, cwd, home) {
  try {
    const snap = { t0: Date.now(), cwd: cwd || '' };
    if (cwd && git(cwd, ['rev-parse', '--is-inside-work-tree'])) {
      snap.numstat = numstat(cwd);
    }
    writeFileSync(join(stateDir(home), `turn.${sid || 'nosession'}.json`), JSON.stringify(snap));
  } catch { /* fail-open */ }
}

function loadTurn(sid, home) {
  const p = join(stateDir(home), `turn.${sid || 'nosession'}.json`);
  try {
    const snap = JSON.parse(readFileSync(p, 'utf8'));
    unlinkSync(p);
    return snap;
  } catch {
    return null;
  }
}

function diffFacts(snap, cwd) {
  if (!cwd || !snap || !snap.numstat) return null;
  const now = numstat(cwd);
  if (!now) return null;
  const before = snap.numstat;
  const files = [];
  let ins = 0, del = 0;
  for (const [f, [i, d]] of Object.entries(now)) {
    const prev = before[f];
    if (prev && prev[0] === i && prev[1] === d) continue;   // unchanged this turn
    files.push(f);
    if (i > 0) ins += i - (prev && prev[0] > 0 ? prev[0] : 0);
    if (d > 0) del += d - (prev ? prev[1] : 0);
  }
  if (!files.length) return null;
  return { files: files.length, names: files.slice(0, 3).map(f => basename(f)), insertions: Math.max(0, ins), deletions: Math.max(0, del) };
}

// Transcript scan: the last test/build command of the turn and how it ended.
// Claude Code's Stop payload carries transcript_path; agents without one just
// skip these collectors.
function transcriptFacts(transcriptPath, t0) {
  if (!transcriptPath || !existsSync(transcriptPath)) return {};
  let lines;
  try { lines = readFileSync(transcriptPath, 'utf8').split('\n').slice(-TRANSCRIPT_TAIL); } catch { return {}; }

  const pendingBash = {};   // tool_use id -> command
  let tests = null, build = null, errors = 0, edits = 0;
  const editedFiles = new Set();

  for (const line of lines) {
    if (!line.includes('"type"')) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    const ts = o.timestamp ? Date.parse(o.timestamp) : NaN;
    if (t0 && !Number.isNaN(ts) && ts < t0) continue;

    const content = o?.message?.content;
    if (!Array.isArray(content)) continue;
    for (const block of content) {
      if (block.type === 'tool_use') {
        if (block.name === 'Bash' || block.name === 'PowerShell') {
          const cmd = String(block.input?.command || '');
          pendingBash[block.id] = cmd;
        } else if (block.name === 'Edit' || block.name === 'Write' || block.name === 'NotebookEdit') {
          edits += 1;
          if (block.input?.file_path) editedFiles.add(block.input.file_path);
        }
      } else if (block.type === 'tool_result') {
        const cmd = pendingBash[block.tool_use_id];
        const isError = block.is_error === true;
        if (isError) errors += 1;
        if (!cmd) continue;
        const resultText = typeof block.content === 'string'
          ? block.content
          : Array.isArray(block.content) ? block.content.map(c => c.text || '').join('\n') : '';
        if (TEST_RUNNERS.test(cmd)) {
          tests = { ran: true, status: isError ? 'fail' : 'pass', ...parseCounts(resultText) };
        } else if (BUILD_TOOLS.test(cmd)) {
          build = { ran: true, status: isError ? 'fail' : 'pass' };
        }
      }
    }
  }
  return { tests, build, errors, edits, editedFiles: editedFiles.size };
}

// Best-effort pass/fail counts from common runner output; absent when unsure.
function parseCounts(text) {
  let m;
  if ((m = text.match(/(\d+)\s+fail(?:ed|ing)?[\s\S]{0,80}?(\d+)\s+pass(?:ed|ing)?/i))) return { failed: +m[1], passed: +m[2] };
  if ((m = text.match(/(\d+)\s+pass(?:ed|ing)?[\s\S]{0,80}?(\d+)\s+fail(?:ed|ing)?/i))) return { passed: +m[1], failed: +m[2] };
  if ((m = text.match(/Tests:\s+(\d+)\s+failed,\s+(\d+)\s+passed/i))) return { failed: +m[1], passed: +m[2] };
  if ((m = text.match(/ℹ pass (\d+)[\s\S]{0,40}?ℹ fail (\d+)/))) return { passed: +m[1], failed: +m[2] };
  return {};
}

// Called by the stop hook. Returns { facts, sentence, contradiction, intent }.
export function collectFacts(sid, payload, home, modelText) {
  const started = Date.now();
  const facts = {};
  try {
    const snap = loadTurn(sid, home);
    const cwd = payload.cwd || (snap && snap.cwd) || '';
    if (snap && snap.t0) facts.duration = Math.round((Date.now() - snap.t0) / 1000);

    if (Date.now() - started < 1000) {
      const diff = diffFacts(snap, cwd);
      if (diff) facts.diff = diff;
    }
    const t = transcriptFacts(payload.transcript_path, snap && snap.t0);
    if (t.tests) facts.tests = t.tests;
    if (t.build) facts.build = t.build;
    if (t.errors) facts.errors = t.errors;
    if (t.edits) facts.edits = t.edits;
  } catch { /* fail-open: speak without facts */ }

  return {
    facts,
    sentence: factsSentence(facts),
    contradiction: contradiction(facts, modelText),
  };
}

// Deterministic, short, and first: "3 files, 60 lines. Tests failing, 2 of 40."
export function factsSentence(facts) {
  const parts = [];
  if (facts.diff) {
    const f = facts.diff;
    const lines = f.insertions + f.deletions;
    parts.push(`${f.files} ${f.files === 1 ? 'file' : 'files'}${lines ? `, ${lines} lines` : ''}.`);
  } else if (facts.edits) {
    parts.push(`${facts.edits} ${facts.edits === 1 ? 'edit' : 'edits'}.`);
  }
  if (facts.tests) {
    if (facts.tests.status === 'fail') {
      const n = facts.tests.failed != null && facts.tests.passed != null
        ? `, ${facts.tests.failed} of ${facts.tests.failed + facts.tests.passed}` : '';
      parts.push(`Tests failing${n}.`);
    } else {
      parts.push('Tests passing.');
    }
  }
  if (facts.build && facts.build.status === 'fail') parts.push('Build failing.');
  return parts.join(' ');
}

// P2-3: when the model claims success and the measurements disagree, say so.
export function contradiction(facts, modelText) {
  const failing = (facts.tests && facts.tests.status === 'fail') || (facts.build && facts.build.status === 'fail');
  if (!failing) return '';
  if (!SUCCESS_CLAIMS.test(String(modelText || ''))) return '';
  const what = facts.tests && facts.tests.status === 'fail' ? 'Tests failing' : 'Build failing';
  return `${what}, but the summary claims success.`;
}
