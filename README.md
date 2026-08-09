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

Claude Code is fully built and tested end to end.

Codex is supported and its contract has been checked against the
[Codex hooks reference](https://doc.jarvisuni.com/openai/codex/hooks.html), which
confirms everything agent-voice relies on: `session_id` is a common field on every
event, so per-session state and the `voice ...` commands work; `UserPromptSubmit`
stdout is "added as extra developer context", so the summary instruction lands;
exit code 2 blocks a prompt with stderr as the reason, so the commands are
intercepted; and `Stop` provides `last_assistant_message`. The `hooks.json` shape
agent-voice writes also matches a working Codex hook. What has *not* happened is a
live end-to-end run, so please still report anything odd.

There is a known upstream bug,
[openai/codex#23784](https://github.com/openai/codex/issues/23784): on Windows,
Codex sends hooks malformed JSON when the assistant message contains non-ASCII
text, typically leaving a string unterminated. That is easy to hit, since a single
curly quote or emoji anywhere in a reply is enough. agent-voice works around it:
when the payload will not parse, it scrapes `session_id` and the `<spoken>` block
straight out of the raw text and unescapes them, so the reply is still spoken and
the `voice ...` commands still work. Verified against a payload reproducing the
bug, on both hooks.

Kimi supports the summary text via `UserPromptSubmit`, but its `Stop` event does
not currently expose the assistant's final message, so spoken audio is pending
upstream support. On Kimi it degrades gracefully: you still get the text TL;DR,
just no sound.

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

You need the agent(s) already installed, which is where Node comes from. Python 3
is needed only if you want edge-tts or Kokoro; the installer checks for it and
says so plainly if it is missing, rather than leaving you with a broken choice.

**Windows** (PowerShell):

```
git clone https://github.com/HalbonLabs/agent-voice.git
cd agent-voice
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

**macOS / Linux** (Terminal):

```
git clone https://github.com/HalbonLabs/agent-voice.git
cd agent-voice
bash install.sh
```

The installer detects which supported agents are actually on your machine and
offers them as a checklist: Up/Down to move, Space to toggle, `A` for all, Enter
to confirm. Anything already wired up is pre-ticked and marked, and anything not
found is greyed out and labelled, so you can still pick it if you are about to
install it. When stdin is not a real terminal (piped input, CI) it falls back to
the older comma-separated prompt.

Re-running the installer later is safe: it strips its own previous hook entries
before adding them again, so nothing is ever duplicated. Use it to add another
agent or change engine.

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
| Kokoro offline    | Good      | Free          | Nothing leaves the machine             | Python, ~300 MB |
| Native offline    | Robotic   | Free          | Nothing leaves the machine             | Nothing |

Only the short summary paragraph is ever sent anywhere. Your full conversation,
code, and files are never sent by agent-voice. For everything to stay on the
machine, choose Kokoro or Native.

**Kokoro** is the pick if you want a natural voice with nothing leaving your
machine. It runs [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), an
Apache-2.0 open-weights model, locally on the CPU, and gives you 54 voices across
9 languages, all inside the one download, so switching voice costs nothing.

It is also the fastest engine here, because it does not wait on a network round
trip. Measured on CPU with torch 2.13:

| Engine | Time to produce the audio |
| ------ | ------------------------- |
| Kokoro, warm | **1.7s** |
| edge-tts | 2.6s |
| Kokoro, first reply after install | ~12s |

Those are synthesis times, measured the same way for both. The hook itself adds
about a second of process startup on top, whichever engine you pick.

That needs one piece of machinery to be true. A fresh Python process spends 6.2s
importing PyTorch and 2.4s building the pipeline before it does 1.6s of actual
synthesis, and the Stop hook runs a fresh process every reply. So agent-voice
keeps a **warm daemon** (`kokoro_serve.py`): the model loads once, and each reply
is just the 1.6s of synthesis. Details:

- It listens on loopback only, on an OS-assigned port, and requires a token from
  a file only your account can read. It will only write into its own state dir.
- It costs about 1.7 GB of RAM while resident, and exits by itself after 15 idle
  minutes. `uninstall` shuts it down immediately.
- If it is not running, synthesis still works, it just takes the slow ~12s path
  and starts a daemon for next time. There is nothing to manage by hand.

You do not need to install `espeak-ng` separately: the `espeakng-loader`
dependency bundles it. The installer pre-fetches the weights and a small spaCy
language model, and warms the daemon, so your first spoken reply is quick.

**Native** stays the zero-dependency floor: it installs nothing, downloads
nothing, and uses the voice already built into Windows or macOS. It just sounds
robotic. Every engine falls back to Native if it fails, so agent-voice degrades
to "sounds basic" rather than going silent.

## Daily use

Type these as a normal message in any agent session. They are intercepted by the
hook, act on that session only, and never reach the model:

- `voice on`     summary plus spoken audio
- `voice text`   summary only, no audio
- `voice off`    back to normal long replies, no summary, no audio
- `voice status` show this session's state and the engine it will use
- `voice engine <name>` use a different engine in this session only, where
  `<name>` is `edge`, `kokoro`, `elevenlabs` or `native`. `voice engine default`
  goes back to the installed choice.

`voice engine` is how you compare voices without reinstalling: set one window to
`edge` and another to `kokoro` and they will speak differently at the same time.
Switching to `kokoro` also starts warming the model straight away, so the first
reply on it is not slow.

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
- Kokoro: easiest is to re-run the installer, which lists all 54 voices with their
  published quality grades and lets you **hear each one before choosing** (Up/Down
  to move, `P` to play a sample, Enter to pick). Or set `kokoro_voice` by hand, for
  example `bf_emma` (British female, the default and the best-graded British voice
  at B-), `bm_george` (British male, C) or `af_heart` (American female, A), plus
  `kokoro_speed` (1.0 is normal, default 1.15). Grades vary a lot, so it is worth
  listening rather than guessing. Full list:
  [VOICES.md](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md).
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
- `kokoro-tts.py`                   local synthesiser (Kokoro engine only)
- `kokoro_serve.py`                 warm daemon that keeps the model loaded
- `kokoro_engine.py`                the synthesis itself, shared by those two
- `lib/*.mjs`                       small Node helpers (JSON parsing, config merge)
- `state/`                          per-session flags and temp audio

Registration is idempotent: any existing hook entry that references `agent-voice`
is removed before the current one is added, so re-installing, upgrading, or adding
another agent never creates duplicates. Nothing else in your agent configs is
touched.

## Privacy

agent-voice only ever sends the short `<spoken>` summary to a cloud voice engine,
and only if you choose edge-tts or ElevenLabs. It never sends your prompts, the
full replies, your code, or your files anywhere. Choose Kokoro or Native for zero
network calls at speaking time. Kokoro downloads its weights once at install and
is fully local from then on; Native never touches the network at all.

## License

MIT. See LICENSE.
