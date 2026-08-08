# agent-voice

Turn a coding agent's long replies into a short, plain-language summary you can
read in one glance, and optionally hear spoken aloud in a natural voice.

agent-voice adds a `<spoken>` "TL;DR in human words" to the end of every reply,
then reads just that summary out loud. It works across multiple AI coding agents
that support hooks (Claude Code, Codex CLI, Kimi Code CLI), on Windows and macOS.

Pairs perfectly with dictation tools like Wispr Flow: speak your prompt in, get a
concise summary back out.

## The problem it solves

Coding agents often reply at length, with jargon and detail. In a busy team it is
hard to pull out what actually changed and what the agent needs from you.
agent-voice asks the agent to finish every reply with a 2 to 3 sentence summary
written to be heard, not read: what changed since your last message, and the one
decision (if any) it needs. The full detailed answer still appears above, intact.

You get two things from that:

1. A **text TL;DR** at the bottom of every reply, in normal words.
2. Optional **spoken audio** of just that summary, in a natural voice.

You choose per session whether you want the audio, just the text, or nothing.

## Supported agents

| Agent          | Config file                     | Summary text | Spoken voice |
| -------------- | ------------------------------- | ------------ | ------------ |
| Claude Code    | `~/.claude/settings.json`       | Yes          | Yes          |
| Codex CLI      | `~/.codex/hooks.json`           | Yes          | Yes (test it)|
| Kimi Code CLI  | `~/.kimi-code/config.toml`      | Yes          | Pending      |

Claude Code is fully built and tested. Codex uses the same hook events and fields
(`UserPromptSubmit`, `Stop`, `last_assistant_message`), so it is supported the same
way; please smoke-test it in your environment. Kimi supports the summary text via
`UserPromptSubmit`, but its `Stop` event does not currently expose the assistant's
final message, so spoken audio is pending upstream support. On Kimi it degrades
gracefully: you still get the text TL;DR, just no sound.

## How it works

agent-voice is two hooks per agent (no app, no background service):

- A **UserPromptSubmit** hook injects a short instruction each turn asking the
  agent to end its reply with a `<spoken>` summary block.
- A **Stop** hook reads that block when the reply finishes and speaks it with your
  chosen voice engine.

All supported agents pass a JSON payload to hooks on stdin, so the same core
scripts serve every agent. Only the config file where the hooks are registered
differs, and the installer handles that per agent.

State is per session, keyed on the session id, so you can have one window talking
and others silent.

## Install

You need the agent(s) already installed (each ships with Node, which this uses).
Then, from the repo folder:

**Windows** (PowerShell):

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

**macOS / Linux** (Terminal):

```
bash install.sh
```

The installer asks which agents to enable, which voice engine to use, wires the
hooks into each agent's config without touching anything else already there, and
(on Windows) adds a global stop hotkey. Reload any open agent session afterwards
so it picks up the hooks.

## Choosing a voice engine

The installer offers three, with a description of each:

| Engine            | Quality   | Cost          | Privacy                                | Needs   |
| ----------------- | --------- | ------------- | -------------------------------------- | ------- |
| edge-tts (Ava)    | Very good | Free          | Summary text sent to Microsoft's TTS   | Python  |
| ElevenLabs        | Best      | Your API plan | Summary text sent to ElevenLabs        | API key |
| Native offline    | Robotic   | Free          | Nothing leaves the machine             | Nothing |

Only the short summary paragraph is ever sent anywhere. Your full conversation,
code, and files are never sent by agent-voice. For everything to stay on the
machine, choose Native offline.

## Daily use

Type these as a normal message in any agent session. They are intercepted by the
hook, act on that session only, and never reach the model:

- `voice on`     summary plus spoken audio
- `voice text`   summary only, no audio
- `voice off`    back to normal long replies, no summary, no audio
- `voice status` show the current session's state

Global controls:

- **Stop speech now:** Windows `Ctrl+Alt+S` (or run `shush.cmd`); macOS run
  `~/.agent-voice/shush.sh` (bind it to a key with the Shortcuts app if you like).
- **Global default on/off:** Windows `~/.agent-voice/voice.cmd`; macOS
  `~/.agent-voice/voice.sh`. Sessions with no per-session setting follow this.

Tip: do not run voice in two sessions at once unless you want both talking. Use
`voice off` in the ones you are not listening to.

## Changing the voice

Edit `~/.agent-voice/config`:

- edge-tts: set `edge_voice`, for example `en-GB-SoniaNeural` (British female) or
  `en-US-AvaNeural`. List voices with `python -m edge_tts --list-voices`.
- ElevenLabs: set `eleven_voice` to a voice id. Free accounts can use only the
  built-in premade voices via the API; paid accounts unlock the premium library.
- Native (macOS): set `native_voice` to an installed voice name.

## Uninstall

**Windows:** `powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1`
**macOS / Linux:** `bash uninstall.sh`

This removes the agent-voice hooks from every agent config and the stop hotkey,
and offers to delete `~/.agent-voice`. Reload open sessions afterwards.

## Under the hood

Everything installs to `~/.agent-voice`:

- `voice-context.*` and `speak.*`   the two hook scripts
- `config`                          your engine and voice choices
- `elevenlabs-key`                  your key, if you chose ElevenLabs (local only)
- `lib/*.mjs`                       small Node helpers (JSON parsing, config merge)
- `state/`                          per-session flags and temp audio

Registration is idempotent: any existing hook entry that references `agent-voice`
is removed before the current one is added, so re-installing, upgrading, or adding
another agent never creates duplicates. Nothing else in your agent configs is
touched.

## Privacy

agent-voice only ever sends the short `<spoken>` summary to a cloud voice engine,
and only if you choose edge-tts or ElevenLabs. It never sends your prompts, the
full replies, your code, or your files anywhere. Choose Native offline if you want
zero network calls.

## License

MIT. See LICENSE.
