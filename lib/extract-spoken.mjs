// Extracts the cleaned <spoken> block from an assistant reply. Used two ways:
// imported by the Node hooks, and as a stdin CLI by the legacy shell hooks.
//
// Takes the LAST block, and requires its content not to contain another opening
// tag. Both matter: a naive non-greedy match runs from the first <spoken> to the
// first </spoken>, so one mistyped closing tag earlier in the reply makes it span
// two blocks and read the entire reply aloud, with no way to tell it is happening
// until you are listening to it.
import { pathToFileURL } from 'url';

const BLOCK = /<spoken>((?:(?!<spoken>)[\s\S])*?)<\/spoken>/g;

export function extractSpoken(text) {
  const all = [...String(text).matchAll(BLOCK)];
  if (!all.length) return '';
  // The leading-dash strip is defence in depth for R-14: this text reaches
  // `say` in an argv position, and a block starting "-o /tmp/x" must never be
  // readable as a flag even if the -- guard at the call site is lost.
  return all[all.length - 1][1].replace(/[`*#_>|]/g, '').replace(/\s+/g, ' ').trim().replace(/^-+/, '');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let d = '';
  process.stdin.on('data', c => d += c).on('end', () => {
    process.stdout.write(extractSpoken(d));
  });
}
