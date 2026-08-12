// Phase 5: reach. Gating rules, and the ntfy/webhook POSTs against a local
// server so no test touches the network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { shouldNotify, shouldPush, notificationParts, pushRemote } from '../src/notify.mjs';

const job = (over = {}) => ({ tag: 's1', text: 'the summary', intent: 'failed', duration: 300, cwd: '/w/checkout-api', ...over });

test('notifications fire only on problem intents and can be disabled', () => {
  assert.equal(shouldNotify(job({ intent: 'failed' }), {}), true);
  assert.equal(shouldNotify(job({ intent: 'question' }), {}), true);
  assert.equal(shouldNotify(job({ intent: 'done' }), {}), false);
  assert.equal(shouldNotify(job({ intent: 'failed' }), { voice_notify: '0' }), false);
});

test('push needs a target, a problem intent, and a long turn', () => {
  const cfg = { ntfy_topic: 't' };
  assert.equal(shouldPush(job(), cfg), true);
  assert.equal(shouldPush(job(), {}), false, 'no target configured');
  assert.equal(shouldPush(job({ intent: 'done' }), cfg), false);
  assert.equal(shouldPush(job({ duration: 30 }), cfg), false, 'short turn');
  assert.equal(shouldPush(job({ duration: 30 }), { ...cfg, voice_push_secs: '10' }), true, 'threshold configurable');
});

test('notification parts carry intent and project, and clamp the body', () => {
  const p = notificationParts(job({ text: 'x'.repeat(500) }));
  assert.equal(p.title, 'agent-voice: failed in checkout-api');
  assert.equal(p.body.length, 240);
});

test('pushRemote posts to ntfy and the webhook', async () => {
  const seen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      seen.push({ url: req.url, headers: req.headers, body });
      res.end('ok');
    });
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;

  try {
    await pushRemote(job({ intent: 'question', text: 'Should I use JWT?' }), {
      ntfy_topic: 'my-agent',
      ntfy_server: `http://127.0.0.1:${port}`,
      webhook_url: `http://127.0.0.1:${port}/hook`,
    });
    assert.equal(seen.length, 2);
    const ntfy = seen.find(s => s.url === '/my-agent');
    assert.ok(ntfy, 'ntfy request seen');
    assert.equal(ntfy.body, 'Should I use JWT?');
    assert.equal(ntfy.headers.priority, 'high');
    assert.match(ntfy.headers.title, /question in checkout-api/);
    const hook = seen.find(s => s.url === '/hook');
    const payload = JSON.parse(hook.body);
    assert.equal(payload.intent, 'question');
    assert.equal(payload.project, 'checkout-api');
  } finally {
    server.close();
  }
});

test('pushRemote survives a dead server without throwing', async () => {
  await pushRemote(job(), { ntfy_server: 'http://127.0.0.1:1', ntfy_topic: 'x' });
});
