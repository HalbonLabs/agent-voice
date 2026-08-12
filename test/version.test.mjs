// R-21: one version, three places that must agree. The VERSION file is the
// source; package.json and the register.mjs ownership marker must match it,
// and this test is what makes "single source" mechanically true.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const version = readFileSync(join(ROOT, 'VERSION'), 'utf8').trim();

test('VERSION is a semver', () => {
  assert.match(version, /^\d+\.\d+\.\d+$/);
});

test('package.json agrees with VERSION', () => {
  const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'));
  assert.equal(pkg.version, version);
});

test('register.mjs ownership marker agrees with VERSION', () => {
  const src = readFileSync(join(ROOT, 'lib', 'register.mjs'), 'utf8');
  const m = src.match(/const VERSION = '([^']+)'/);
  assert.ok(m, 'register.mjs must declare its VERSION constant');
  assert.equal(m[1], version);
});
