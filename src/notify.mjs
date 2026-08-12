// Reach beyond the terminal (P5). If you are in a meeting or on another
// desktop, speech is useless and a notification is not; for genuinely long
// runs your pocket should buzz. Both are gated hard: only the three problem
// intents notify, and push additionally requires the turn to have been long,
// because nobody wants their phone buzzing for every edit.
import http from 'http';
import https from 'https';
import { basename } from 'path';

const PROBLEM_INTENTS = new Set(['question', 'blocked', 'failed']);
const DEFAULT_PUSH_SECS = 120;
const NTFY_DEFAULT = 'https://ntfy.sh';

export function shouldNotify(job, cfg) {
  if (cfg.voice_notify === '0') return false;
  return PROBLEM_INTENTS.has(job.intent);
}

export function shouldPush(job, cfg) {
  if (!cfg.ntfy_topic && !cfg.webhook_url) return false;
  if (!PROBLEM_INTENTS.has(job.intent)) return false;
  const threshold = cfg.voice_push_secs === undefined ? DEFAULT_PUSH_SECS : Number(cfg.voice_push_secs);
  return (Number(job.duration) || 0) >= threshold;
}

export function notificationParts(job) {
  const proj = job.cwd ? basename(job.cwd) : '';
  const title = proj ? `agent-voice: ${job.intent} in ${proj}` : `agent-voice: ${job.intent}`;
  const body = String(job.text).length > 240 ? String(job.text).slice(0, 237) + '...' : String(job.text);
  return { title, body };
}

function post(url, body, headers, timeoutMs = 8000) {
  return new Promise(resolve => {
    try {
      const mod = url.startsWith('http:') ? http : https;
      const req = mod.request(url, { method: 'POST', headers, timeout: timeoutMs }, res => {
        res.resume();
        res.on('end', () => resolve(res.statusCode));
      });
      req.on('error', () => resolve(null));
      req.on('timeout', () => { req.destroy(); resolve(null); });
      req.end(body);
    } catch {
      resolve(null);
    }
  });
}

// ntfy first (no account, self-hostable, one POST), plus a generic webhook
// for Slack/Discord/Teams shims. Fire-and-forget with a timeout; a dead
// server never delays anything the user can hear.
export async function pushRemote(job, cfg) {
  const { title, body } = notificationParts(job);
  const jobs = [];
  if (cfg.ntfy_topic) {
    const server = (cfg.ntfy_server || NTFY_DEFAULT).replace(/\/+$/, '');
    const tags = { question: 'grey_question', blocked: 'no_entry', failed: 'x' }[job.intent] || 'loudspeaker';
    jobs.push(post(`${server}/${encodeURIComponent(cfg.ntfy_topic)}`, body, {
      Title: title,
      Priority: job.intent === 'question' ? 'high' : 'default',
      Tags: tags,
      'Content-Type': 'text/plain; charset=utf-8',
    }));
  }
  if (cfg.webhook_url) {
    jobs.push(post(cfg.webhook_url, JSON.stringify({
      source: 'agent-voice',
      intent: job.intent,
      project: job.cwd ? basename(job.cwd) : '',
      duration_seconds: Number(job.duration) || 0,
      text: job.text,
    }), { 'Content-Type': 'application/json' }));
  }
  await Promise.all(jobs);
}
