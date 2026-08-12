# Configuration and daily-use reference

The README covers the commands themselves; this is the detail.

## Choosing settings without memorising anything

Each of the three settings (`voice engine`, `voice model`, `voice speed`)
lists what is available first, marks what is in use, and takes a number, so
nothing has to be recalled exactly. Numbers for Kokoro index the full
catalogue, which is ordered English first, so they stay the same whether or
not the other languages are on screen. Speed is deliberately not numbered,
because 1 and 2 are themselves valid speeds and a numbered menu would be
ambiguous.

`voice preview` and `voice pick` are Kokoro only, since it is the one engine
that synthesises locally and instantly. `voice pick` opens a separate window
because the hook cannot read keystrokes: it runs non-interactively with stdin
carrying the JSON payload, so a window with its own keyboard is the only way
to get arrow keys. It is the same picker the installer uses, from the same
file.

`voice engine` is how you compare voices without reinstalling: set one window
to `edge` and another to `kokoro` and they will speak differently at the same
time. Switching to `kokoro` also starts warming the model straight away, so
the first reply on it is not slow. The voice override is stored per engine,
so switching engine never carries a Kokoro id over to edge-tts where it would
mean nothing.

`voice speed` exists because a spoken summary you have already half-read is
usually something you want to get through quickly. It is one scale across
every engine, and each converts it to whatever it actually wants: Kokoro
takes the multiplier directly, edge-tts takes a percentage delta, and the
native voices take their own rate scale. ElevenLabs has no rate control in
this integration, so it ignores speed and `voice status` says so.

## Stop shortcuts

- **`voice stop`** (or `shush`) in any session works on both platforms, needs
  no setup, and stops speech in every session.
- **Windows** gets `Ctrl+Alt+S` registered at install.
- **macOS** has no scriptable global-hotkey API, so the installer builds a
  **Stop agent-voice** Quick Action and you assign the key yourself: System
  Settings > Keyboard > Keyboard Shortcuts > Services > General, find it,
  click `none`, and press your keys. `Cmd+Alt+S` matches the Windows one.
- **Global default on/off:** Windows `~/.agent-voice/voice.cmd`; macOS
  `~/.agent-voice/voice.sh`. Sessions with no per-session setting follow it.

## When it did not speak, and why

`voice last` explains the previous turn's decision: spoke, earcon only, or
suppressed, and the reason (rate limited, another session had the floor,
snoozed, policy). `voice snooze [minutes]` mutes all audio everywhere for a
while (default 30; notifications still show); `voice snooze off` ends it.

## Several sessions at once

Audio is global, but the summary is not: keep `voice on` in the window you
are listening to and put the others on `voice text`. Every window still gets
the text TL;DR, just without several voices talking over each other. This
matters because the installer turns voice on globally, so a second window
starts out speaking too; one `voice text` in it is enough.

## The config file

`~/.agent-voice/config`, plain `key=value`, parsed (never executed). Usually
you change these in-session instead; the file sets the machine-wide default.

| Key | Applies to | Example |
| --- | ---------- | ------- |
| `engine` | all | `kokoro` |
| `kokoro_voice`, `kokoro_speed` | Kokoro | `af_heart`, `1.15` |
| `edge_voice`, `edge_rate` | edge-tts | `en-GB-SoniaNeural`, `+15%` |
| `eleven_voice`, `eleven_model` | ElevenLabs | a voice id from your account |
| `native_voice` | Native, macOS | an installed system voice |
| `voice_speed` | all | `1.25`, overrides the per-engine speed |
| `voice_style` | wording | `plain` (default) / `standard` / `technical` / `detailed` |
| `voice_humanize` | delivery | `off` (default) / `subtle` / `chatty`: written hesitations and, at chatty, the odd half-laugh |
| `voice_pause_ms` | audio | breath between spoken sentences on streamed engines (default 250, 0 disables) |
| `voice_when` | policy | `always` / `problem` / `question` / `long` / `never` |
| `voice_long_secs` | policy | threshold for `long` mode (default 45) |
| `voice_min_secs` | policy | turns shorter than this are earcon-only outside `always` (default 15, 0 disables) |
| `voice_earcons` | audio | `0` disables the intent tones |
| `voice_notify` | reach | `0` disables desktop notifications on problem turns |
| `ntfy_topic` | reach | an [ntfy](https://ntfy.sh) topic; problem turns over the push threshold buzz your phone |
| `ntfy_server` | reach | self-hosted ntfy server (default `https://ntfy.sh`) |
| `webhook_url` | reach | generic JSON webhook for Slack/Discord/Teams shims |
| `voice_push_secs` | reach | minimum turn length before a push (default 120) |
| `python_cmd` | edge-tts, Kokoro | the interpreter the hooks should use |

Audio ducking and output-device selection are deliberately not implemented:
both need native audio APIs (CoreAudio, the Windows audio session API) that
cannot be reached honestly from a dependency-free install. They will come
with a platform-native helper if demand shows up.

`python_cmd` is written by the installer and is worth leaving alone: it pins
the interpreter inside `~/.agent-voice/venv`, the one that actually has the
dependencies. The hooks inherit the PATH of whichever agent launched them,
and a project virtualenv earlier on that PATH would otherwise be picked and
silently fail down to the robotic voice.

## Voice quality notes

Kokoro's grades vary a lot, so listen rather than guess: `bf_emma` is the
best British voice at B-, every British male tops out at C, and the highest
graded overall is `af_heart` at A. Full list:
[VOICES.md](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md).
For edge-tts, `python -m edge_tts --list-voices` prints the hundreds it
supports. Grades are the model's own.

## What lands where on disk

Everything installs to `~/.agent-voice`:

- `voice-context.*`, `speak.*`: the two hook scripts
- `config`: engine, voice, speed, interpreter
- `elevenlabs-key`: your key, if you chose ElevenLabs (local only, mode 600)
- `kokoro-tts.py`, `kokoro_serve.py`, `kokoro_engine.py`: local synthesis and
  the warm daemon
- `pick-voice.*`: the arrow-key voice picker, shared with the installer
- `shush.*`, `voice.*`: stop speech, and the global on/off toggle
- `lib/*.mjs`, `lib/kokoro-voices.json`: Node helpers and the voice catalogue
- `venv/`: the private Python environment the installer builds
- `state/`: per-session flags and temp audio (owner-only)

`pick-voice.*` and `kokoro-voices.json` are deliberately shared between the
installer and the running hooks so the picker and the voice ids cannot drift
between what you can install and what you can switch to.
