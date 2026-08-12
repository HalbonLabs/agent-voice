// The four synthesis engines. Each returns true only if audio was actually
// produced AND played; anything less falls through to the native voice, so
// agent-voice degrades to "sounds basic", never to silence.
import { spawnSync } from 'child_process';
import { existsSync, statSync, readFileSync, writeFileSync, unlinkSync } from 'fs';
import { join } from 'path';
import https from 'https';
import { platform } from './platform/index.mjs';
import { rootDir } from './config.mjs';

// A "wav" under this size is a header with no audio in it.
const MIN_AUDIO_BYTES = 500;

function producedAudio(file) {
  try { return existsSync(file) && statSync(file).size > MIN_AUDIO_BYTES; } catch { return false; }
}
function cleanup(file) {
  try { unlinkSync(file); } catch { /* already gone */ }
}

function speakEdge(job) {
  // edge-tts wants a percentage delta, so 1.25x becomes +25%.
  const mul = Number(job.speed);
  const pct = isFinite(mul) ? Math.round((mul - 1) * 100) : 15;
  const rate = pct >= 0 ? `+${pct}%` : `${pct}%`;
  const r = spawnSync(job.python,
    ['-m', 'edge_tts', '--text', job.text, '--voice', job.voice, `--rate=${rate}`, '--write-media', job.mp3],
    { stdio: 'ignore' });
  return r.status === 0 && producedAudio(job.mp3) && platform.play(job.mp3);
}

// Conservative sentence split; anything unsplittable stays one utterance.
function splitSentences(text) {
  const parts = String(text).match(/[^.!?]+[.!?]+(?:\s+|$)|[^.!?]+$/g) || [text];
  return parts.map(s => s.trim()).filter(Boolean);
}

// Streaming synthesis (P4-1): synthesise sentence 1, start playing it, and
// synthesise the rest while it plays. The facts-first template makes the
// first sentence short by construction, so perceived latency is one short
// synthesis, not the whole utterance's.
async function speakKokoro(job) {
  const script = join(rootDir(job.home), 'kokoro-tts.py');
  if (!existsSync(script)) return false;

  const synth = (text, out) => {
    const r = spawnSync(job.python, [script, out, job.voice, String(job.speed)],
      { input: text, stdio: ['pipe', 'ignore', 'ignore'] });
    return r.status === 0 && producedAudio(out);
  };

  const sentences = splitSentences(job.text);
  if (sentences.length <= 1) {
    return synth(job.text, job.wav) && platform.play(job.wav);
  }

  let playing = null;
  let spokeAny = false;
  for (let i = 0; i < sentences.length; i++) {
    const wavPath = job.wav.replace(/\.wav$/, `.${i}.wav`);
    const ok = synth(sentences[i], wavPath);
    if (!ok) {
      // Mid-stream failure: finish the remaining words with the native voice
      // rather than re-speaking from the start or going quiet.
      if (playing) await playing;
      platform.speakNative(sentences.slice(i).join(' '), { speed: job.speed, voice: job.nativeVoice });
      return true;
    }
    if (playing) await playing;
    playing = platform.playAsync(wavPath, job.python).then(done => { cleanup(wavPath); return done; });
    spokeAny = true;
  }
  if (playing) await playing;
  return spokeAny;
}

async function speakEleven(job) {
  const keyFile = join(rootDir(job.home), 'elevenlabs-key');
  if (!existsSync(keyFile)) return false;
  const key = readFileSync(keyFile, 'utf8').trim();
  if (!key) return false;
  const body = JSON.stringify({
    text: job.text,
    model_id: job.model,
    voice_settings: { stability: 0.5, similarity_boost: 0.75, style: 0.0, use_speaker_boost: true },
  });
  const audio = await httpsPost(
    `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(job.voice)}?output_format=mp3_44100_128`,
    body,
    { 'xi-api-key': key, 'Content-Type': 'application/json' },
  );
  if (!audio) return false;
  writeFileSync(job.mp3, audio);
  return producedAudio(job.mp3) && platform.play(job.mp3);
}

// Node's https is async by nature; the speaker is a dedicated process with
// nothing else to do, so a promise wrapped in a deasync-free busy-wait is not
// needed: speak() awaits it.
function httpsPost(url, body, headers) {
  return new Promise(resolve => {
    const req = https.request(url, { method: 'POST', headers, timeout: 20000 }, res => {
      if (res.statusCode !== 200) { res.resume(); resolve(null); return; }
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => resolve(Buffer.concat(chunks)));
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.end(body);
  });
}

export async function speak(job) {
  cleanup(job.mp3);
  cleanup(job.wav);
  let spoke = false;
  try {
    if (job.engine === 'edge') spoke = speakEdge(job);
    else if (job.engine === 'kokoro') spoke = await speakKokoro(job);
    else if (job.engine === 'elevenlabs') spoke = await speakEleven(job);
  } catch {
    spoke = false;
  }
  // Fallback: the offline native voice, so a failure sounds basic, not silent.
  if (!spoke) {
    platform.speakNative(job.text, { speed: job.speed, voice: job.nativeVoice });
  }
  cleanup(job.mp3);
  cleanup(job.wav);
}
