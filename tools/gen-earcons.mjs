// Generates the four intent earcons as small PCM WAVs into data/earcons/.
// Run once at build time (node tools/gen-earcons.mjs); the outputs are
// committed so installs need no generation step. You learn four tones in a
// day, and after that the tool can speak far less often and still keep you
// informed (P3-1):
//   question  rising two-tone      it needs a decision, go look
//   done      soft single tone     finished, nothing wrong
//   blocked   flat double tone     cannot proceed, external cause
//   failed    descending two-tone  it tried and it did not work
import { writeFileSync, mkdirSync } from 'fs';
import { fileURLToPath } from 'url';
import { join, dirname } from 'path';

const RATE = 22050;
const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', 'data', 'earcons');
mkdirSync(OUT, { recursive: true });

// One tone: sine with a fast attack and exponential decay, gentle level.
function tone(freq, ms, level = 0.28) {
  const n = Math.round(RATE * ms / 1000);
  const samples = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const t = i / RATE;
    const attack = Math.min(1, i / (RATE * 0.008));
    const decay = Math.exp(-3.2 * (i / n));
    samples[i] = Math.sin(2 * Math.PI * freq * t) * attack * decay * level;
  }
  return samples;
}

function silence(ms) {
  return new Float64Array(Math.round(RATE * ms / 1000));
}

function concat(parts) {
  const total = parts.reduce((a, p) => a + p.length, 0);
  const out = new Float64Array(total);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

function wav(samples) {
  const data = Buffer.alloc(samples.length * 2);
  for (let i = 0; i < samples.length; i++) {
    data.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(samples[i] * 32767))), i * 2);
  }
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(RATE, 24); h.writeUInt32LE(RATE * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

const earcons = {
  // C5 then G5: unmistakably "up", a question mark in sound.
  question: concat([tone(523.25, 130), silence(30), tone(783.99, 170)]),
  // One soft E5: acknowledgement, nothing to look at.
  done: concat([tone(659.25, 160, 0.22)]),
  // A4 twice, flat: a knock on a door that will not open.
  blocked: concat([tone(440, 110), silence(60), tone(440, 110)]),
  // D5 down to G4: deflating, it did not work.
  failed: concat([tone(587.33, 130), silence(30), tone(392, 190)]),
};

for (const [name, samples] of Object.entries(earcons)) {
  writeFileSync(join(OUT, `${name}.wav`), wav(samples));
  console.log(`wrote ${name}.wav (${samples.length} samples)`);
}
