import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const PY_TEST = join(HERE, 'test_kokoro_serve.py');

// The daemon needs 3.9+ for stdlib-only import; any working interpreter will do
// for these pure-function tests. Store aliases and absent commands both throw.
function findPython() {
  for (const cmd of ['python3', 'python']) {
    try {
      const v = execFileSync(cmd, ['--version'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
      if (/Python 3\./.test(v)) return cmd;
    } catch { /* try the next name */ }
  }
  return null;
}

test('kokoro_serve pure functions (python)', t => {
  const py = findPython();
  if (!py) return t.skip('no Python 3 on PATH');
  let out;
  try {
    out = execFileSync(py, [PY_TEST], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    assert.fail('python tests failed:\n' + (e.stdout || '') + (e.stderr || ''));
  }
  assert.ok(true, out);
});
