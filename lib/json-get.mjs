// Reads a JSON object from stdin and prints one top-level field's value.
// Usage:  echo '{"a":1}' | node json-get.mjs a
//
// Codex on Windows can send hooks malformed JSON when the assistant message
// contains non-ASCII text (openai/codex#23784), typically leaving a string
// unterminated. Rather than returning nothing and letting the reply go silent, a
// parse failure falls back to scraping the requested field out of the raw text.
const ESCAPES = { n: '\n', r: '\r', t: '\t', b: '\b', f: '\f', '"': '"', '\\': '\\', '/': '/' };

function unescapeJson(s) {
  return s.replace(/\\(u[0-9a-fA-F]{4}|[\s\S])/g, (_, e) =>
    e[0] === 'u' ? String.fromCharCode(parseInt(e.slice(1), 16)) : (ESCAPES[e] ?? e));
}

function salvage(raw, key) {
  // Deliberately does not require the closing quote, since an unterminated string
  // is the known failure mode: take the longest run of valid string content.
  const m = raw.match(new RegExp('"' + key + '"\\s*:\\s*"((?:[^"\\\\]|\\\\[\\s\\S])*)'));
  return m ? unescapeJson(m[1]) : '';
}

let d = '';
process.stdin.on('data', c => d += c).on('end', () => {
  d = d.replace(/^﻿/, '');        // PowerShell prefixes piped stdin with a BOM
  const key = process.argv[2];
  try {
    const v = JSON.parse(d)[key];
    process.stdout.write(v == null ? '' : String(v));
  } catch {
    process.stdout.write(salvage(d, key));
  }
});
