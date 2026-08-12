// Every repo-relative path literal mentioned in the source must exist. This is
// the class of bug that turns a working checkout into a broken install: a
// script referencing a helper that was renamed, moved, or never committed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SOURCE_EXT = /\.(sh|ps1|mjs|py|cmd)$/;
const SKIP_DIRS = new Set(['.git', 'node_modules', '__pycache__']);
// A literal that starts with a known top-level source dir and ends in a source
// or data extension. Deliberately narrow: matching every slash-containing
// string drowns the check in installer-target false positives.
const PATH_LIT = /\b(?:core|lib|test|data)[\\/][A-Za-z0-9_.\\/-]+\.(?:sh|ps1|mjs|py|json|cmd)\b/g;

function* sourceFiles(dir) {
  for (const name of readdirSync(dir)) {
    if (SKIP_DIRS.has(name)) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* sourceFiles(p);
    else if (SOURCE_EXT.test(name)) yield p;
  }
}

test('every repo-relative path referenced in source exists', () => {
  const missing = [];
  for (const file of sourceFiles(ROOT)) {
    const text = readFileSync(file, 'utf8');
    for (const m of text.matchAll(PATH_LIT)) {
      const rel = m[0].replace(/\\/g, '/');
      if (!existsSync(join(ROOT, rel))) {
        missing.push(`${file}: ${m[0]}`);
      }
    }
  }
  assert.deepEqual(missing, [], 'referenced paths that do not exist:\n' + missing.join('\n'));
});
