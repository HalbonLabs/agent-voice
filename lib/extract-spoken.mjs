// Reads assistant message text from stdin, prints the cleaned <spoken> block.
// Prints nothing if there is no <spoken> block.
let d = '';
process.stdin.on('data', c => d += c).on('end', () => {
  const m = d.match(/<spoken>([\s\S]*?)<\/spoken>/);
  if (!m) { process.stdout.write(''); return; }
  const t = m[1].replace(/[`*#_>|]/g, '').replace(/\s+/g, ' ').trim();
  process.stdout.write(t);
});
