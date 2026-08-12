// Reads one top-level field out of a hook payload. Used two ways: imported by
// the Node hooks, and as a stdin CLI (echo '{"a":1}' | node json-get.mjs a) by
// the legacy shell hooks.
//
// Codex on Windows can send hooks malformed JSON when the assistant message
// contains non-ASCII text (openai/codex#23784), typically leaving a string
// unterminated. Rather than returning nothing and letting the reply go silent, a
// parse failure falls back to scraping the requested field out of the raw text.
// The BOM strip covers PowerShell's piped stdin, and Cursor has the same class
// of bug, so this is a portable hardening layer, not a one-vendor workaround.
import { pathToFileURL } from 'url';

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

export function getField(raw, key) {
  const cleaned = String(raw).replace(/^﻿/, '');
  try {
    const v = JSON.parse(cleaned)[key];
    return v == null ? '' : String(v);
  } catch {
    return salvage(cleaned, key);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let d = '';
  process.stdin.on('data', c => d += c).on('end', () => {
    process.stdout.write(getField(d, process.argv[2]));
  });
}
