// Extracts the cleaned <spoken> block from an assistant reply. Used two ways:
// imported by the Node hooks, and as a stdin CLI by the legacy shell hooks.
//
// Takes the LAST block, and requires its content not to contain another opening
// tag. Both matter: a naive non-greedy match runs from the first <spoken> to the
// first </spoken>, so one mistyped closing tag earlier in the reply makes it span
// two blocks and read the entire reply aloud, with no way to tell it is happening
// until you are listening to it.
import { pathToFileURL } from 'url';

// The optional intent attribute (P2-4/P3-1) classifies the turn:
// done | question | blocked | failed. Unknown or absent means 'done'.
const BLOCK = /<spoken(?:\s+intent="([a-z]+)")?\s*>((?:(?!<spoken)[\s\S])*?)<\/spoken>/g;
const OPEN = /<spoken(?:\s+intent="([a-z]+)")?\s*>/g;
const INTENTS = new Set(['done', 'question', 'blocked', 'failed']);

// A block whose closing tag was forgotten is the commonest way a turn goes
// silent: the model writes the words, ends the reply, and the strict match
// above finds nothing at all. Recover that tail, but only while it is short
// enough to BE a spoken block. The length is what keeps the strictness the
// header describes: a tag opened mid-reply and never closed leaves the whole
// remaining reply as its tail, which is exactly the case that must stay silent
// rather than be read out. 400 is roughly double the longest block observed in
// practice, against a contract that asks for one or two short sentences.
const RECOVER_MAX = 400;

function recoverUnclosed(text) {
  const opens = [...text.matchAll(OPEN)];
  if (!opens.length) return null;
  const last = opens[opens.length - 1];
  const tail = text.slice(last.index + last[0].length);
  // Closed after all, so the normal path owns it.
  //
  // Do NOT delete this as unreachable. It looks dead once recovery is gated on
  // the strict match finding nothing, and for well-formed tags it is. It still
  // fires on a MALFORMED fragment: BLOCK's `(?!<spoken)` lookahead trips on any
  // literal "<spoken" substring, including a bare one with no closing ">" that
  // could never open a block itself. So `<spoken intent="done"><spoken</spoken>
  // </spoken>` yields zero BLOCK matches, reaches here, and is correctly
  // declined because a real closing tag IS present in the tail. That path exits
  // silent with no stderr line, which is the right call (we cannot tell which
  // fragment was meant to be spoken) but is worth knowing when it happens.
  if (tail.includes('</spoken>')) return null;
  if (tail.length > RECOVER_MAX) return null;
  return { raw: tail, intent: last[1] };
}

// Markdown strip, whitespace collapse, then the leading-dash strip: defence in
// depth for R-14, because this text reaches `say` in an argv position and a
// block starting "-o /tmp/x" must never be readable as a flag even if the --
// guard at the call site is lost.
const clean = s => s.replace(/[`*#_>|]/g, '').replace(/\s+/g, ' ').trim().replace(/^-+/, '');

export function extractSpokenWithIntent(text) {
  const str = String(text);
  const all = [...str.matchAll(BLOCK)];

  // Recovery is a LAST resort, reached only when nothing parsed. It must never
  // outrank a block that was written correctly: a reply that closes its block
  // and then mentions the tag again in passing still has a real message, and
  // speaking the trailing fragment instead would be worse than the silence this
  // recovery exists to fix. Silence is visibly wrong; confidently speaking the
  // wrong words is not.
  if (!all.length) {
    const salvaged = recoverUnclosed(str);
    if (!salvaged) return { text: '', intent: 'done' };
    // Say so rather than repairing it invisibly: a silently-fixed mistake is
    // one nobody knows they are still making. `voice last` surfaces this.
    process.stderr.write('agent-voice: spoken block had no closing tag; recovered the tail\n');
    return { text: clean(salvaged.raw), intent: INTENTS.has(salvaged.intent) ? salvaged.intent : 'done' };
  }

  const last = all[all.length - 1];
  return { text: clean(last[2]), intent: INTENTS.has(last[1]) ? last[1] : 'done' };
}

export function extractSpoken(text) {
  return extractSpokenWithIntent(text).text;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let d = '';
  process.stdin.on('data', c => d += c).on('end', () => {
    process.stdout.write(extractSpoken(d));
  });
}
