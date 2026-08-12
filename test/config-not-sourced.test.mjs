// R-11: the config file is data, never code. A command substitution planted in
// a value must not execute when the Stop hook reads its config.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir, platform } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join, dirname } from 'node:path';

const SPEAK = join(dirname(fileURLToPath(import.meta.url)), '..', 'core', 'macos', 'speak.sh');

test('a command substitution in the config does not execute', { skip: platform() === 'win32' }, () => {
  const home = mkdtempSync(join(tmpdir(), 'av-home-'));
  const root = join(home, '.agent-voice');
  mkdirSync(join(root, 'state'), { recursive: true });
  const marker = join(home, 'pwned');
  writeFileSync(join(root, 'config'), [
    'engine=native',
    `eleven_voice=x$(touch ${marker})`,
    'edge_voice=`touch ' + marker + '2`',
    '',
  ].join('\n'));
  writeFileSync(join(root, 'state', 'voice-on'), '');

  const payload = JSON.stringify({
    session_id: 'cfgtest',
    last_assistant_message: '<spoken>config safety check</spoken>',
  });
  execFileSync('bash', [SPEAK], { env: { ...process.env, HOME: home }, input: payload, encoding: 'utf8' });

  assert.equal(existsSync(marker), false, 'command substitution must not run');
  assert.equal(existsSync(marker + '2'), false, 'backtick substitution must not run');
});
