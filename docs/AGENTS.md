# Supported agents

The roster lives in `data/agents.json`; adding an agent is a data change
plus, at most, a payload field in the hooks. Hook contracts below were
verified against vendor documentation on 2026-08-11 (see the research in
ENHANCEMENT_PLAN.md section 7); anything not run live is labelled.

| Agent | Config | Summary | Voice | Notes |
|---|---|---|---|---|
| Claude Code | `~/.claude/settings.json` | yes | yes | most exercised; run live |
| Codex CLI | `~/.codex/hooks.json` | yes | yes | run live; malformed-JSON salvage on Windows |
| Kimi Code CLI | `~/.kimi-code/config.toml` | yes | yes | run live; reply recovered from its transcript |
| Qwen Code | `~/.qwen/settings.json` | yes | yes | config is a near-literal clone of Claude Code's; `last_assistant_message` inline. Not yet run live |
| Droid (Factory) | `~/.factory/hooks.json` | yes | yes | Stop payload is metadata-only; reply recovered via `transcript_path` with the generic reader. Not yet run live |
| Goose | `~/.agents/plugins/agent-voice/hooks/hooks.json` | no | yes | `UserPromptSubmit` is observation-only in Goose, so the summary contract cannot be injected per turn: voice output reads the reply's `<spoken>` block only if something else put one there. Registered stop-only |
| Gemini CLI | `~/.gemini/settings.json` | yes | yes | **experimental**, see below |

## Gemini CLI, honestly

Two documented quirks and one open bug, all handled but unverified live:

- Injection is JSON-stdout only (`hookSpecificOutput` with `BeforeAgent`);
  plain stdout becomes a user-visible systemMessage. The hooks take
  `--agent=gemini` and switch protocol accordingly.
- The reply field is `prompt_response`, which the stop hook reads.
- **[google-gemini/gemini-cli#27712](https://github.com/google-gemini/gemini-cli/issues/27712)**:
  `AfterAgent` configured in settings.json may silently never fire. If your
  turns are silent on Gemini, that bug is the first suspect; reproduce it
  before filing anything here. Needs Gemini CLI v0.30.0+.

Register it explicitly (it is not offered in the installer checklist):

```
node ~/.agent-voice/lib/register.mjs mode=install home=$HOME platform=mac scripts=$HOME/.agent-voice providers=gemini
```

## Amp (in-process plugin)

Amp runs TypeScript plugins in-process rather than shell hooks. A thin shim
that calls the same two hooks lives at `integrations/amp/agent-voice.ts`;
copy it to `~/.config/amp/plugins/`. Untested against a live Amp: treat it
as a starting point, and read the file header before using it.

## Not supported, and why

| Agent | Blocker |
|---|---|
| Cursor CLI | `afterAgentResponse` does not fire in the CLI (vendor-confirmed gap); `stop` carries no reply text |
| GitHub Copilot CLI | no turn-complete event, no documented session id |
| Crush, Amazon Q, Cline | no usable turn-complete hook |
| opencode | no turn-complete hook; `session.idle` needs an SDK round-trip. Beware: a widely-circulated gist documents a `stop` hook that does not exist |
