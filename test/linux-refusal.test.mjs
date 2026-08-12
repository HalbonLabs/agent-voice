// R-10: Linux is refused loudly at install time, never half-installed into
// silence. Runs only where the refusal path is reachable (the Linux CI runner).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { platform } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const INSTALL = join(dirname(fileURLToPath(import.meta.url)), '..', 'install.sh');

test('install.sh refuses to run on Linux, with an explanation', { skip: platform() !== 'linux' }, () => {
  const r = spawnSync('bash', [INSTALL], { encoding: 'utf8', input: '' });
  assert.notEqual(r.status, 0, 'must exit non-zero on Linux');
  assert.match(r.stderr, /macOS only/i);
  assert.match(r.stderr, /Linux is not supported yet/i);
});
