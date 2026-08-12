# Platform and agent status

The honest state of what has been run where, so nothing is a surprise.

| | Windows | macOS | Linux |
|---|---|---|---|
| Status | Tested end to end, all three agents | Install + Kokoro verified on a real Mac; rest listed below | Not supported; installer refuses |

## Windows

The best-tested platform; the project was built here first. All three agents
have been run live end to end. Speech runs in a hidden background child so no
agent waits for it; the hook itself returns in roughly a second, most of which
is PowerShell startup.

## macOS

Verified on a real Mac on 2026-08-10 (macOS 25.5, Apple silicon, Python
3.12.13) by installing and checking each claim rather than trusting the
installer's own output. That run found and fixed three installer defects, so
"verified" means exactly this:

- **Verified:** the installer end to end, Python resolution inside Kokoro's
  3.10 to 3.12 window (a 3.12 install succeeding, 3.9 and 3.13 both
  refused), the private venv, and the Kokoro engine speaking.
- **Still unverified:** `voice pick` (opens Terminal via `osascript` and
  triggers an Automation permission prompt on first use; `voice preview` is
  the setup-free fallback), the edge-tts, ElevenLabs and Native engines on
  macOS, `uninstall.sh` against a real install, and Codex and Kimi on macOS
  at all.

The scripts share the same Node helpers and voice catalogue as Windows and
are kept in lockstep by the parity rule (see CONTRIBUTING.md). If something
on the unverified list misbehaves, please report it rather than working
around it.

## Linux

Not supported: audio playback in the hooks is macOS-specific (`afplay`,
`say`), so an install would complete and then every reply would be silent.
The installer exits with an explanation instead. Support is planned as part
of the cross-platform core rewrite.

## Agent verification notes

**Claude Code** is the most exercised of the three and was built against
first.

**Codex CLI**: the contract was checked against the
[Codex hooks reference](https://doc.jarvisuni.com/openai/codex/hooks.html),
which confirms everything agent-voice relies on: `session_id` on every event,
`UserPromptSubmit` stdout injected as developer context, exit code 2 blocking
a prompt with stderr as the reason, and `Stop` carrying
`last_assistant_message`. Since run live end to end.

There is a known upstream bug,
[openai/codex#23784](https://github.com/openai/codex/issues/23784): on
Windows, Codex sends hooks malformed JSON when the reply contains non-ASCII
text; a single curly quote is enough. agent-voice salvages `session_id` and
the `<spoken>` block from the raw text, verified against a reproducing
payload on both hooks.

**Kimi Code CLI** works, including voice, by a different route: its `Stop`
payload carries no assistant message at all, so the reply is recovered from
Kimi's own session transcript
(`~/.kimi-code/sessions/<workspace>/<session>/agents/main/wire.jsonl`),
taking the last complete assistant text part. That path only runs when
`last_assistant_message` is genuinely absent, so Claude Code and Codex are
untouched. The transcript format is undocumented; if Kimi changes it, Kimi
sessions fall silent rather than misbehaving.
