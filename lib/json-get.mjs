// Reads a JSON object from stdin and prints one top-level field's value.
// Usage:  echo '{"a":1}' | node json-get.mjs a
let d = '';
process.stdin.on('data', c => d += c).on('end', () => {
  try {
    const o = JSON.parse(d);
    const v = o[process.argv[2]];
    process.stdout.write(v == null ? '' : String(v));
  } catch {
    process.stdout.write('');
  }
});
