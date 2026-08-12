# Changelog

All notable changes to agent-voice. Dates are UTC.

## 0.1.0 - 2026-08-12

### Added
- **Grounded summaries**: the Stop hook measures the turn independently of
  the model's self-report: the turn's own git diff (snapshotted at prompt
  time), the last test or build run and how it actually ended, error and
  edit counts, and duration. Facts are spoken first, deterministically, and
  when the model claims success over red tests the reply opens with the
  contradiction and the intent is forced to failed. All collectors are
  fail-open and budgeted.
- **Intent earcons and attention policy**: four short tones mark every
  turn's intent (question, done, blocked, failed) before any words; `voice
  when always|problem|question|long|never` decides whether the words
  follow, with a short-turn watched heuristic, a cross-session rate limit,
  five-minute de-duplication, and multi-session arbitration (question and
  failed cut through from any session, prefixed with the project name).
  Fresh installs default to `problem`.
- **Latency**: Kokoro synthesis is streamed sentence by sentence; the
  earcon plays while synthesis runs; the daemon pre-warms while the model
  thinks. Measured time to first sound ~420 ms from the Stop hook firing.
- **Reach**: desktop notifications on problem turns (osascript / WinRT
  toast), and phone push via ntfy or a generic webhook for problem turns
  over a duration threshold.
- **Agents**: Qwen Code, Droid (Factory), and Goose join Claude Code,
  Codex and Kimi; Gemini CLI ships experimentally (documented open vendor
  bug); an Amp in-process shim ships unexercised. The roster is data
  (`data/agents.json`).
- **Distribution**: Claude Code plugin manifest, `npx agent-voice install`,
  and Homebrew/winget packaging templates.

## Pre-0.1.0 remediation

### Security
- The Kokoro daemon's port/token file is created `0600` before any bytes are
  written, and the state directory is owner-only on both platforms. The token
  is the daemon's entire access control, and it previously landed
  world-readable under the default umask (R-05).
- The daemon only writes allowlisted synthesis filenames inside its state dir,
  so a token holder cannot overwrite `kokoro.port` or the voice flags, and it
  bounds request bodies (64 KB) and text (8 KB) (R-06).
- The config file is parsed, never sourced: a command substitution pasted into
  a value no longer executes on every reply (R-11).
- The ElevenLabs key is passed to curl via a config on stdin, not argv, so it
  no longer shows in `ps`; the Windows installer frees the BSTR copy of the
  key and sets an owner-only ACL on the key file (R-12).
- `session_id` is clamped to `[A-Za-z0-9_-]` before touching any file path
  (R-13), `say` gets `--` before model-controlled text (R-14), and hook
  ownership in agent configs is an explicit marker instead of an
  `agent-voice` substring match that could delete third-party hooks (R-09).

### Fixed
- macOS barge-in: the pidfile recorded the wrong PID (`$$` inside a
  backgrounded subshell), so cutting off the previous turn never worked and a
  stale pidfile could kill an unrelated process after PID reuse. Kills are now
  identity-checked on both platforms, and `voice stop` no longer kills every
  `afplay`/`say` the user is running (R-04, R-15).
- Windows: speech runs in a hidden background child, so Codex and Kimi turns
  no longer block for the whole duration of the spoken summary. Only Claude
  Code has async hooks; every other agent awaits its Stop hook (R-07).
- Both installers resolve Python inside Kokoro's supported window (3.10 to
  3.12), refuse an interpreter that is too new with a message naming the
  range, install dependencies into a private venv at `~/.agent-voice/venv`,
  and check every pip exit code (R-08).
- Agent configs are written atomically with a one-time backup of the
  pre-agent-voice original (R-03).
- The Windows uninstaller quits the Kokoro daemon with the interpreter the
  config recorded, so the ~1.7 GB process no longer survives uninstall (R-16).
- Culture-invariant number handling on Windows: `voice speed 1.5` now works on
  a `de-DE` machine and the state file always contains a dot (R-17).
- A killed daemon's lock is taken over immediately (holder-liveness check)
  instead of after a 180 s grace window (R-19).
- The macOS Quick Action plist XML-escapes the install path (R-20).

### Changed
- The two hooks are now a single Node implementation (`src/`) on every
  platform, replacing the four shell and PowerShell scripts (~1,370 lines
  reduced to ~810 shared ones) that had already drifted apart. The hooks
  return in ~100 ms where the PowerShell pair took ~1.4 s, the `voice ...`
  command surface and every reply string exist exactly once, engine metadata
  lives in `data/engines.json`, and `shush` delegates to the same
  identity-checked stop logic the hooks use. ElevenLabs synthesis now uses
  Node https instead of curl, which also keeps the key out of every process
  list by construction.
- Linux is refused at install time with an explanation instead of completing
  into permanent silence; support is planned as part of the cross-platform
  core rewrite (R-10).
- Test suite (`npm test`, zero dependencies) and three-OS CI added; every fix
  above is covered where a test can reach it (R-01, R-02).

## Pre-history

The project began Windows-first against Claude Code, then added Codex CLI and
Kimi Code CLI. Notable engineering along the way, preserved from the original
README:

- **Codex malformed-JSON workaround.** On Windows, Codex sends hooks malformed
  JSON when the reply contains non-ASCII text
  ([openai/codex#23784](https://github.com/openai/codex/issues/23784)); one
  curly quote is enough. `lib/json-get.mjs` salvages the needed fields from
  the raw text, verified against a reproducing payload.
- **Kimi transcript recovery.** Kimi's Stop payload carries no assistant
  message, so `lib/kimi-last-text.mjs` recovers the reply from the session
  transcript (`wire.jsonl`), taking the last complete assistant text part. If
  Kimi changes the undocumented format, Kimi sessions go quiet rather than
  misbehaving.
- **Command replies through the model.** Hook stderr with exit 2 shows in a
  terminal but not in the VS Code extension, so `voice ...` command replies
  are handed to the model as context with an instruction to repeat them, the
  one channel every client displays.
