// Reads assistant message text from stdin, prints the cleaned <spoken> block.
// Prints nothing if there is no well-formed block.
//
// Takes the LAST block, and requires its content not to contain another opening
// tag. Both matter: a naive non-greedy match runs from the first <spoken> to the
// first </spoken>, so one mistyped closing tag earlier in the reply makes it span
// two blocks and read the entire reply aloud, with no way to tell it is happening
// until you are listening to it.
const BLOCK = /<spoken>((?:(?!<spoken>)[\s\S])*?)<\/spoken>/g;

let d = '';
process.stdin.on('data', c => d += c).on('end', () => {
  const all = [...d.matchAll(BLOCK)];
  if (!all.length) { process.stdout.write(''); return; }
  // The leading-dash strip is defence in depth for R-14: this text reaches
  // `say` in an argv position, and a block starting "-o /tmp/x" must never be
  // readable as a flag even if the -- guard at the call site is lost.
  const t = all[all.length - 1][1].replace(/[`*#_>|]/g, '').replace(/\s+/g, ' ').trim().replace(/^-+/, '');
  process.stdout.write(t);
});
