# Changelog

All notable changes to agent-voice. Dates are UTC.

## Unreleased (0.1.0)

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
