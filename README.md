# agent-voice

Turn a coding agent's long replies into a short, plain-language summary you
can read in one glance, and optionally hear spoken aloud in a natural voice.

agent-voice adds a `<spoken>` "TL;DR in human words" to the end of every
reply, then reads just that summary out loud, prefixed with **measured
facts**: the turn's own diff, whether the tests actually passed, and, when
the model claims success over red tests, it says so. A short intent tone
marks every turn (question, done, blocked, failed), and an attention policy
decides when words follow. Works across six coding agents (Claude Code,
Codex CLI, Kimi Code, Qwen Code, Droid, Goose) on Windows and macOS. Pairs
well with dictation tools like Wispr Flow.

It is two hooks per agent and no application: a `UserPromptSubmit` hook
injects the summary instruction each turn, and a `Stop` hook speaks the block
when the reply finishes. State is per session, so one window can talk while
others stay silent, on different engines and speeds.

## Supported agents and platforms

| Agent | Summary text | Spoken voice |
| ----- | ------------ | ------------ |
| Claude Code | Yes | Yes |
| Codex CLI | Yes | Yes |
| Kimi Code CLI | Yes | Yes (via transcript) |
| Qwen Code | Yes | Yes |
| Droid (Factory) | Yes | Yes (via transcript) |
| Goose | No | Yes |

Gemini CLI is supported experimentally and Amp via an in-process shim; the
per-agent details, including what has and has not been run live, are in
[docs/AGENTS.md](docs/AGENTS.md).

Windows is tested end to end with all three. macOS is verified on a real Mac
for install and the Kokoro engine, with the remaining pieces listed honestly.
Linux is refused at install rather than half-working. Details, including the
Codex malformed-JSON workaround and the Kimi transcript recovery:
[docs/PLATFORM-STATUS.md](docs/PLATFORM-STATUS.md).

## Install

You need the agent(s) already installed, which is where Node comes from.
Python 3 is only needed for the edge-tts and Kokoro engines.

The quickest path needs no clone:

```
npx agent-voice install
```

Or from a clone:

```
git clone https://github.com/HalbonLabs/agent-voice.git
cd agent-voice
```

Then on Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1`
On macOS: `bash install.sh`

Claude Code users can also add it as a plugin (the repo carries a plugin
manifest); the plugin runs with the built-in OS voice out of the box, and
the installer adds the natural-voice engines.

The installer detects your agents, offers them as a checklist, asks which
voice engine to use, wires the hooks in without touching anything else in
your configs (originals are backed up), and sets up a stop shortcut.
Re-running it later is safe and never duplicates. Reload open sessions
afterwards.

## Voice engines

| Engine | Quality | Cost | Privacy | Needs |
| ------ | ------- | ---- | ------- | ----- |
| edge-tts (Ava) | Very good | Free | Summary text sent to Microsoft | Python |
| ElevenLabs | Best | Your API plan | Summary text sent to ElevenLabs | API key |
| Kokoro offline | Good | Free | Nothing leaves the machine | Python, ~300 MB |
| Native offline | Robotic | Free | Nothing leaves the machine | Nothing |

Only the short summary is ever sent anywhere, and only on the two cloud
engines. Every engine falls back to Native on failure, so agent-voice
degrades to "sounds basic", never to silence. Kokoro keeps a warm local
daemon so replies start speaking in ~1.7 s; benchmarks and daemon internals:
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Daily use

Type these as a normal message in any session; the hook intercepts them:

- `voice on` / `voice text` / `voice off`: audio, text-only, or neither
- `voice stop` (or `shush`): stop speech now, every session
- `voice status`: what this session will do and why
- `voice engine`, `voice model`, `voice speed`: list, then pick by number or
  name; add `default` to reset
- `voice preview <n>`, `voice pick`: audition voices (Kokoro)
- `voice list`, `voice help`: the catalogues and all of the above

Windows also gets a global `Ctrl+Alt+S` stop hotkey; macOS gets a Quick
Action to bind. The full reference, multi-session tips, and the config file
keys: [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Uninstall

Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1`
macOS: `bash uninstall.sh`

Removes the hooks from every agent config, stops the Kokoro daemon, and
offers to delete `~/.agent-voice`.

## Privacy

agent-voice never sends your prompts, full replies, code, or files anywhere.
The short summary goes to a cloud engine only if you chose one. Kokoro and
Native make zero network calls at speaking time. The security model and
disclosure policy: [SECURITY.md](SECURITY.md).

## Project

- [CHANGELOG.md](CHANGELOG.md): what has changed, including the honest
  defect history
- [CONTRIBUTING.md](CONTRIBUTING.md): the bash 3.2 rule, the parity rule,
  and how to run the tests
- License: MIT. See LICENSE.
