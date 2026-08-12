// Generic JSONL transcript reader: the last assistant text in the file. Used
// for agents (Droid) whose Stop payload carries only a transcript_path, and
// as a fallback for any future agent with the same shape. Handles the two
// shapes seen in the wild:
//   { message: { role: "assistant", content: [{ type: "text", text }] } }   (Claude-style)
//   { role: "assistant", content: "..." }                                    (flat)
// Unknown formats yield '', which means the reply goes unspoken rather than
// misread: the same honest degradation the Kimi reader documents.
import { readFileSync, existsSync } from 'fs';

const TAIL_LINES = 1500;

export function transcriptLastText(path) {
  if (!path || !existsSync(path)) return '';
  let lines;
  try { lines = readFileSync(path, 'utf8').split('\n'); } catch { return ''; }
  let text = '';
  for (const line of lines.slice(-TAIL_LINES)) {
    if (!line.includes('assistant')) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    const msg = o?.message && typeof o.message === 'object' ? o.message : o;
    if (msg?.role !== 'assistant' && o?.type !== 'assistant') continue;
    const content = msg?.content;
    let t = '';
    if (typeof content === 'string') {
      t = content;
    } else if (Array.isArray(content)) {
      t = content.filter(b => b && b.type === 'text' && typeof b.text === 'string').map(b => b.text).join('\n');
    }
    if (t.trim()) text = t;
  }
  return text;
}
