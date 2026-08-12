# agent-voice: Enhancement Plan

**Goal:** make agent-voice the most useful tool in its category, not the most featured.
**Prerequisite:** `REMEDIATION.md` phases 0 and 1 are closed. Do not start here first.
**Audience:** a coding agent working through this unattended, or a human delegating it.

---

# 1. Thesis

## The job to be done

You set an agent going. It works for 30 seconds to 10 minutes. You context-switch to something else. You need to know, without looking at the terminal:

1. Is it finished?
2. Did it actually work, or does it only claim it did?
3. Does it need a decision from me?

That is the job. It is **ambient awareness of a long-running agent**, and it is not the same job as voice conversation.

## Why this is a real category and not a subset of voicemode

[voicemode](https://github.com/mbailey/voicemode) (1.3k stars) is the biggest project adjacent to this, and it does a different job:

| | voicemode | agent-voice |
|---|---|---|
| Interaction | Modal. Invoke `converse`, chime, you speak, it speaks back | Ambient. You type normally, output arrives alongside |
| Trigger | MCP tool call. **The model decides** whether to invoke it | Stop hook. Fires deterministically, every turn |
| Content | The full response | A short digest |
| Blocks you | Yes, turn-based loop | No |
| Direction | Bidirectional (STT + TTS) | Output only |

The trigger row is the important one. An MCP tool can be skipped, because models skip tool calls. A Stop hook cannot. If the promise is "you will always know when it needs you", only the hook architecture can keep it.

Two supporting facts:

- Claude Code shipped native `/voice` around March 2026. It is **input only**, no spoken responses. The platform has taken the dictation half and left the output half alone.
- Dictation is already solved for this user by Wispr Flow and similar. There is no reason to build STT.

## The actual competitive set

Not voicemode. These:

| Project | Stars | What it does | Gap you can attack |
|---|---:|---|---|
| [ChanMeng666/echook](https://github.com/ChanMeng666/echook) | 78 | 37 hook events, Claude Code + Cursor + Codex, chimes + TTS, webhooks, status line | Notification-shaped, not comprehension-shaped. Announces that something happened, not what it means |
| [ktaletsk/claude-code-tts](https://github.com/ktaletsk/claude-code-tts) | 16 | Kokoro, injected summary instruction, 54 voices, interruption, audio ducking | Claude Code only. Cold-starts Kokoro per reply. No verification of what it speaks |
| [husniadil/cc-hooks](https://github.com/husniadil/cc-hooks) | 18 | ElevenLabs/gTTS, fallback chain, AI contextual messages | Claude Code only, cloud-first |
| [cris-m/claude_voice](https://github.com/cris-m/claude_voice) | 2 | `TTS_SUMMARY` extraction, Kokoro/Chatterbox/MLX | Claude Code only, early |

Every one of them shares the same weakness, and it is the opening.

## The opening: nobody verifies what they speak

All of these tools, agent-voice included, ask the model to summarise itself and then read the answer aloud. **The model's self-report is the weakest signal in the system.** It says "I've successfully implemented authentication" while the test suite is red. You then hear a confident voice tell you it worked, and you trust it, because it sounded certain.

That is worse than silence.

The Stop hook sits in a privileged position that no MCP tool occupies: it has the transcript, the working directory, and the exit codes, at the moment the turn ends. It can compute ground truth independently of what the model claims.

**That is the product.** Not "your agent can talk". **"Your agent tells you the truth about what it just did, and you can hear it from the next room."**

## What this plan explicitly does not build

Say no to these clearly, so the roadmap does not sprawl:

- **STT / dictation.** Solved by the platform and by Wispr Flow.
- **Conversation mode.** Different job, and voicemode has a two-year head start and 1.3k stars of community.
- **A GUI or menu-bar app.** The audience lives in a terminal.
- **More TTS engines.** Four is already one too many to maintain. See P1-1.
- **Notification-event breadth.** echook does 37 hook events. Chasing that is chasing the wrong axis, and losing.

---

# 2. Phase 1: the architecture unlock

**Nothing else in this plan is affordable until this is done.**

## P1-1 Move the core to Node, keep only audio platform-specific

**The problem, in numbers.** `core/macos/voice-context.sh` is 427 lines. `core/windows/voice-context.ps1` is 479 lines. They are the same 14-command state machine, written twice. `speak.sh` (130) and `speak.ps1` (215) are the same engine chain, twice. `install.sh` (523) and `install.ps1` (310), the same wizard, twice. Roughly **1,900 of the 2,900 lines in this repo are one thing implemented two ways**, with no mechanism keeping them in sync.

**It has already drifted.** `voice-context.sh:177` prints `Grades are the model own.`; `voice-context.ps1:252` prints the correct `Grades are the model's own.` And `voice-context.ps1` duplicates the edge-tts shortlist twice **within the same file** (inline at `:262-264`, again as `$EDGE_SHORTLIST` at `:286-287`), directly beneath a comment at `:285` claiming they are "kept next to the display so they cannot diverge". They have already diverged structurally.

Every feature in phases 2 through 6 costs double and drifts by default until this is fixed.

**Node is free.** Every supported agent ships Node. The hooks already shell out to it five times (`extract-spoken.mjs`, `json-get.mjs`, `register.mjs`, `eleven-body.mjs`, `kimi-last-text.mjs`). There is no new dependency here.

**Target shape:**

```
src/
  hook-prompt.mjs        UserPromptSubmit: build and inject the contract
  hook-stop.mjs          Stop: parse, gather facts, decide, speak
  commands/              the 14 `voice ...` commands, one file each
  facts/                 ground-truth collectors (Phase 2)
  policy.mjs             should we speak at all (Phase 3)
  engines/
    kokoro.mjs  edge.mjs  eleven.mjs  native.mjs
  platform/
    darwin.mjs           afplay, say, osascript, notification
    win32.mjs            MCI, SAPI, toast
    linux.mjs            paplay/aplay/ffplay, spd-say, notify-send
  config.mjs             one parser, replacing the sed reader and the `source`
data/
  voices.json            already exists as lib/kokoro-voices.json
  strings.json           all user-facing text, currently duplicated
  engines.json           engine metadata, currently duplicated
```

Platform files should be **under 80 lines each**: play a file, speak with the native voice, show a notification, list native voices. Everything else is shared.

**Migration order** (each step ships independently, nothing big-bang):

1. `data/strings.json` + `data/engines.json`, both platforms read them. Kills the drift immediately, before any rewrite.
2. `src/config.mjs`, replacing `speak.sh:11`'s `source` (this also closes REMEDIATION R-11) and `voice-context.sh:18`'s `sed` reader.
3. `src/hook-stop.mjs`. Register it directly as the Stop hook. Delete `speak.sh` and `speak.ps1`.
4. `src/hook-prompt.mjs`. Same for `voice-context.*`.
5. The installer stays a shell script per platform (it must run before Node is guaranteed on PATH), but shrinks to: detect agents, detect Python, build the venv, call `node src/install.mjs` for everything else.

**Acceptance:**
- Total LOC drops by 35% or more with no feature lost.
- One place to change any user-facing string, verified by a CI check that no string in `strings.json` appears literally in any `.sh` or `.ps1`.
- The full command surface passes tests on all three OS runners.
- Adding a fifth platform would mean writing one file under 80 lines.

**Effort:** the single largest item in this plan. Roughly 3 to 5 days. Everything after it is 2 to 3 times cheaper.

---

# 3. Phase 2: grounded summaries (the flagship)

This is the differentiator. Build it immediately after Phase 1.

## P2-1 Collect ground truth in the Stop hook

The Stop hook computes facts about the turn that just ended, independent of anything the model said.

**Collectors, in priority order:**

| Collector | Source | Output |
|---|---|---|
| `diff` | `git diff --shortstat` and `--name-only` against a snapshot taken at UserPromptSubmit | files changed, insertions, deletions, up to 3 filenames |
| `tests` | scan the transcript for tool calls matching known test runners (`jest`, `vitest`, `pytest`, `go test`, `cargo test`, `npm test`, `dotnet test`) and read their exit code and tail output | ran / did not run, pass / fail, counts if parseable |
| `build` | same, for `tsc`, `next build`, `cargo build`, `go build`, `dotnet build` | ran / did not run, exit code, error count |
| `errors` | tool results in the transcript with non-zero exit or an error field | count, first error line |
| `duration` | UserPromptSubmit timestamp to Stop timestamp | seconds |
| `edits` | count of Edit/Write tool calls in the transcript | number, distinct files |

Snapshot the git state in `hook-prompt.mjs` and stash it at `state/turn.<sid>.json`. Diff against it in `hook-stop.mjs`. Handle the non-repo case by degrading to `edits` only.

Collectors must be **fail-open**: any collector that throws or exceeds a 300 ms budget is dropped, and the turn still speaks. Ground truth is an enhancement, never a dependency.

## P2-2 Speak facts, narrate with the model

The current design speaks only the model's prose. Change the split:

- **Facts come from the collectors.** Deterministic, always true.
- **The model supplies only the narrative clause and the decision**, which is the part it is actually good at.

Template, rendered by `hook-stop.mjs`:

```
[facts]  Four files, sixty lines. Tests failing, three of forty.
[model]  It's asking whether to use JWT or server sessions.
```

Compare that with today's output for the same turn:

```
I've implemented the authentication flow with JWT tokens and added
tests. Let me know if you'd like me to adjust the token expiry.
```

The second one is confident, fluent, and does not mention that the tests are red. That gap is the entire product.

## P2-3 Contradiction detection

When the model's summary claims success and the facts disagree, **say so out loud**.

```
"Tests failing, but the summary claims it's done. Three of forty red."
```

Implementation: a small set of claim patterns (`fixed`, `working`, `passing`, `done`, `complete`, `successfully`) checked against `tests.status` and `build.status`. Keep it narrow and high-precision. A false contradiction alarm destroys trust faster than a missed one.

This single feature is worth more than every other item in this plan. Nobody in the category has it, and it is the reason a sceptical engineer would install a talking tool.

## P2-4 Tighten the injected contract

`voice-context.sh:420-426` currently asks for prose. Replace with a structured contract:

```
End your reply with:
<spoken intent="done|question|blocked|failed" >
One or two sentences. What you decided or need, in plain words.
Do NOT state file counts, line counts, or test results: those are
measured independently and will be spoken for you.
Do NOT claim success. Say what you did.
</spoken>
```

Explicitly forbidding the model from reporting metrics does two things: it stops it inventing numbers, and it shortens the utterance, which matters because attention is the scarce resource here.

**Phase 2 acceptance:**
- On a turn where tests fail and the model claims success, the spoken output states the failure.
- On a non-git directory, output degrades to edit counts with no error.
- Collector budget is enforced: a hung `git` call does not delay speech past 300 ms.
- Facts are correct on a repo with staged, unstaged and untracked changes.

---

# 4. Phase 3: intent and attention policy

The failure mode of every tool in this category is that it talks too much, and you turn it off in week two. Attention is the scarce resource. Spend it deliberately.

## P3-1 Intent classification and earcons

The `intent` attribute from P2-4 drives a distinct short tone before the speech:

| Intent | Earcon | Meaning |
|---|---|---|
| `question` | rising two-tone | It needs a decision. Go look. |
| `done` | soft single tone | Finished, nothing wrong. |
| `blocked` | flat double tone | Cannot proceed, external cause. |
| `failed` | descending tone | It tried and it did not work. |

You learn four tones in a day. After that you do not need the words for most turns, which means the tool can speak far less often and still keep you informed. Derive intent from facts where they disagree with the model's own label (tests red plus a `done` claim becomes `failed`).

## P3-2 Silence policy

```
voice when question    speak only when it needs a decision
voice when problem     question, blocked, failed
voice when long        anything over N seconds (default 45)
voice when always      current behaviour
voice when never       earcon only, no speech
```

Default to `problem`, not `always`. The current installer turns speech on globally for every session with no prompt (`install.sh:509`, `install.ps1:280`) and the README then tells you to fix it per window (`README.md:337`). That is a poor first run for something that makes your computer talk. Invert it: `problem` by default, `voice when always` is one command away.

## P3-3 Presence detection

Cheap heuristics that make the tool feel considerate:

- **Turn under 15 s** (configurable): you were watching. Earcon only.
- **User typed within the last 10 s**: they are at the keyboard. Text only. Detect via the UserPromptSubmit timestamp.
- **Terminal focused**: on macOS, `lsappinfo front`; on Windows, `GetForegroundWindow`. If your agent's terminal is the front window, you can read it. Suppress speech.
- **Rate limit**: never more than one utterance per 20 s across all sessions. Queue or drop, do not overlap.
- **De-duplicate**: never speak a summary substantially identical to one spoken in the last 5 minutes. Cheap normalised-token comparison is enough.

## P3-4 Multi-session arbitration

`README.md:331-338` currently makes this the user's problem: keep one window on `voice on`, the rest on `voice text`. Solve it instead.

Sessions register in a shared state file with their cwd and last-activity time. The Stop hook only speaks if this session is the **most recently active** one, or if the intent is `question` or `failed`, which should always cut through. Prefix cross-session utterances with the project name: "In `checkout-api`: tests failing."

That turns "several voices talking over each other" into a feature: you can run five agents and still follow all of them.

**Phase 3 acceptance:**
- Five concurrent sessions produce no overlapping speech.
- A 5 s turn while the terminal is focused produces an earcon and no speech.
- `voice when question` stays silent through ten successful turns and speaks on the eleventh, which asks something.

---

# 5. Phase 4: latency

Kokoro warm at 1.7 s is already the best in the category (ktaletsk shells out to the `kokoro-tts` CLI cold on every reply, roughly 12 s). Push it to where it stops being noticeable.

## P4-1 Streaming synthesis

Split the utterance on sentence boundaries. Synthesise sentence 1, **start playback**, synthesise the rest during playback, append to the queue.

A short first sentence synthesises in roughly 400 ms. Perceived latency drops from ~1.7 s to under 600 ms, and the fact-first template from P2-2 makes the first sentence short by construction ("Four files, sixty lines. Tests failing.").

Requires the daemon to stream chunks rather than write a single WAV, and the player to accept a queue. On macOS, `afplay` per chunk with a small pre-buffer is sufficient. Extend the `kokoro_serve.py` protocol with a `stream: true` mode that emits length-prefixed PCM frames.

## P4-2 Pre-warm on prompt submit

`hook-prompt.mjs` fires at the start of the turn. Use it to ensure the daemon is warm, so the model's thinking time doubles as synthesis warm-up. Free latency.

## P4-3 Speculative synthesis of the earcon

Emit the earcon the instant the Stop hook fires, before synthesis completes. You know the intent from the tag before you have the audio. Time-to-first-sound becomes effectively zero, and the earcon is the part that carries most of the information anyway (P3-1).

**Phase 4 acceptance:** measured time from Stop hook invocation to first audible sound is under 250 ms for the earcon and under 700 ms for the first spoken word, on a warm daemon. Publish the measurements in `docs/PERFORMANCE.md` with the method, as the current README does.

---

# 6. Phase 5: reach beyond the terminal

## P5-1 Desktop notification alongside speech

If you are in a meeting, or your terminal is on another desktop, speech is useless and a notification is not. Send both, with the summary as the body and the intent as the title. `osascript -e 'display notification'` on macOS, `BurntToast` or a raw toast on Windows, `notify-send` on Linux. Click-to-focus the terminal is a bonus, not required.

## P5-2 Push to phone

For genuinely long runs, you want your pocket to buzz. Support [ntfy](https://ntfy.sh) (no account required, self-hostable, one HTTP POST) as the default, plus a generic webhook for Slack, Discord and Teams.

Gate it: push only on `question`, `blocked` and `failed`, and only when the turn exceeded a threshold. Nobody wants their phone buzzing for every edit. echook has webhooks already, so this is table stakes, not differentiation. Build it cheaply and move on.

## P5-3 Audio ducking

Lower other applications' volume while speaking, restore afterwards. ktaletsk has this on macOS and it is noticeably nicer than talking over your own music. macOS via `osascript` on the system volume or CoreAudio; Windows via the audio session API.

## P5-4 Output device selection and call suppression

```
voice device          list output devices, mark the one in use
voice device 2        route speech to a specific device
```

Plus: if an input device is currently in use by another process (you are on a call), suppress speech and fall back to notification. This is a small touch that people notice and remember.

**Phase 5 acceptance:** a `failed` intent on a 4-minute turn produces speech, a desktop notification, and a phone push. A `done` intent on a 20-second turn produces an earcon only.

---

# 7. Phase 6: agent breadth

This is your structural moat. ktaletsk, husniadil and cris-m are Claude Code only. echook does three. You already do three, and after Phase 1 each additional one is a `data/agents.json` entry plus a handler in `register.mjs`.

**Contracts verified 2026-08-11.** An earlier draft of this plan listed Cursor CLI as the highest-priority addition. **That was wrong**, and the research below is why. Do not work from the old ordering.

Two requirements define whether an agent is viable: **(a)** a prompt-submission event whose output is injected into model context, and **(b)** a turn-complete event that either carries the reply text or points at a transcript.

## Tier 1: near drop-in, both requirements met with reply text inline

Ship these first. Each is close to a config-template change plus a field-name map.

| Agent | Config | (a) prompt-submit | (b) turn-complete | Session key |
|---|---|---|---|---|
| **Qwen Code** | `.qwen/settings.json` | `UserPromptSubmit` → `additionalContext`, wrapped in `<qwen:user-prompt-submit-context>` | `Stop`, payload has **`last_assistant_message`** | `session_id` |
| **Gemini CLI** | `~/.gemini/settings.json` (also project and `/etc`) | `BeforeAgent` → `hookSpecificOutput.additionalContext` | `AfterAgent`, payload has **`prompt_response`** | `session_id` |
| **Goose** | `~/.agents/plugins/<name>/hooks/hooks.json` | `UserPromptSubmit` exists but is **observation-only**, no injection documented | `Stop`, payload has **`last_assistant_message`** | `session_id` |

**Qwen Code is the single best next target.** Its config shape is a near-literal clone of Claude Code's `{"hooks": {"Event": [{"matcher":..., "hooks": [{"type":"command","command":...}]}]}}`, it has the largest open-source install base of the three, and `last_assistant_message` means zero transcript parsing.

**Gemini CLI caveats, both real:**

- Injection is **JSON stdout only**. Plain-text stdout on exit 0 becomes `systemMessage`, which is displayed to the user and **not** injected into model context. This differs from Claude Code, where `UserPromptSubmit` stdout becomes context directly. Your `voice-context` output must be wrapped as `{"hookSpecificOutput": {"hookEventName": "BeforeAgent", "additionalContext": "..."}}`.
- **Open bug [google-gemini/gemini-cli#27712](https://github.com/google-gemini/gemini-cli/issues/27712)** (P2, filed 2026-06-06, still open): `AfterAgent` never executes when configured in `settings.json`, silently, with no error. Reproduce this before committing to Gemini. If it bites, the reporter's workaround was reading the previous turn's response from the chat log during the *next* `BeforeAgent`, which is ugly but works. Version floor is v0.30.0, hooks enabled by default.
- A quirk worth guarding: if a hook's stdout is empty, Gemini parses **stderr as JSON instead**. Logging to stderr from a hook that prints nothing can accidentally become its return value.

**Goose** has no prompt-submit injection, so the `<spoken>` contract cannot be delivered per turn. Either inject once at session start, or use Goose read-only (speak whatever the reply's last paragraph says). Lower value, note it honestly.

## Tier 2: viable, needs a transcript reader you already have

| Agent | Config | (a) | (b) | Session key |
|---|---|---|---|---|
| **Droid (Factory)** | `~/.factory/hooks.json`, `.factory/hooks.json` | `UserPromptSubmit`, stdout adds context on exit 0, plus `additionalContext` | `Stop` fires but payload is metadata only; reply text needs the JSONL at `~/.factory/projects/.../session.jsonl` via `transcript_path` | `session_id` |

This is **exactly the Kimi Code shape**, and `lib/kimi-last-text.mjs` already solves it. Generalise that module to take a transcript path and a format descriptor, and Droid becomes almost free. Good enterprise and paid traction.

## Tier 3: viable, but a rewrite as an in-process TypeScript plugin

Neither of these has a shell-command hook contract. Both run plugins in-process under Bun, and both give you a shell escape so your existing scripts are reachable from a thin shim rather than being rewritten.

| Agent | Plugin path | (a) | (b) |
|---|---|---|---|
| **Amp** | `~/.config/amp/plugins/*.ts`, `.amp/plugins/` | `agent.start`, return `{message: {content}}` to append to the user message | `agent.end`, carries `messages[]` with the full assistant reply inline. **Better payload fidelity than Claude Code**, no parsing at all. Session key is `thread.id` |
| **opencode** | `.opencode/plugin/*.ts`, `~/.config/opencode/plugin/` | `chat.message`, mutate `output.parts` in place. Confirmed working: the hook receives the same array that is persisted and sent to the model | **No turn-complete hook exists.** Closest is `session.idle` (payload is `{sessionID}` only, then query the SDK for messages) or `experimental.text.complete` (has text, but fires per text-part, not per turn) |

Amp is the better of the two and the shim is roughly 20 lines calling out to your binary via `amp.$`. opencode needs `session.idle` plus an SDK round-trip, or on-disk reads from `~/.local/share/opencode/storage/session/`.

One trap: a widely-circulated opencode plugin gist documents a `stop` hook. **It does not exist.** Unknown hook keys are silently never called, so you would ship something that appears to install and never fires.

## Tier 4: blocked, do not build yet

| Agent | Why not |
|---|---|
| **Cursor CLI** | **`beforeSubmitPrompt` and `afterAgentResponse` do not fire in the CLI.** Cursor staff called `afterAgentResponse` "a known gap, tracked internally as a bug" (Mar 2026), with no ETA as of the last statement found (Apr 2026). `stop` does fire in the CLI but its payload is `{status, loop_count}`, no assistant text. Also, there is no `session_id` outside `sessionStart`; the stable key is `conversation_id`. Both of your requirements are unmet. |
| **GitHub Copilot CLI** | Real hooks (`sessionStart`, `userPromptSubmitted`, `preToolUse`) but **no turn-complete event and no documented session id**. The one big-audience miss. Watch it. |
| **Crush (Charm)** | `PreToolUse` only. Tracking [charmbracelet/crush#2707](https://github.com/charmbracelet/crush/issues/2707). |
| **Amazon Q Developer CLI** | Context hooks only (`conversation_start`, `per_prompt`). Stdout is injected, 10 KB cap, but there is no completion hook. |
| **Cline** | Shell hooks are documented for the VS Code extension only, and `TaskComplete` carries `{"task": string}` with no reply text. The SDK plugin hooks are in-process TS with unstated CLI applicability. |
| Aider, Roo Code, Continue, Warp, Zed, Devin CLI, Plandex | No deterministic hook system as of Aug 2026. Zed maintainers lean toward ACP instead. |

## Revised ordering

```
1. Qwen Code      Tier 1, largest win per unit effort, near-literal config clone
2. Droid          Tier 2, reuses lib/kimi-last-text.mjs
3. Gemini CLI     Tier 1, but reproduce #27712 first and budget for the JSON-stdout difference
4. Amp            Tier 3, small TS shim, best payload fidelity of anything surveyed
5. Goose          Tier 1 for output, no input injection, so partial value
6. opencode       Tier 3, most work for least certainty
   Cursor CLI     blocked, revisit when afterAgentResponse fires in the CLI
```

That takes you from 3 agents to 8. No competitor is close.

## Two findings that change other phases

**1. Nobody else supports async hooks.** Claude Code's `async: true` is unique. Gemini explicitly waits for every hook. Cursor has only a timeout. opencode's trigger hooks are fully awaited. Amp's are awaited. This makes **REMEDIATION R-07 option (b), backgrounding the work inside `speak` itself, the mandatory choice rather than a preference.** Option (a), relying on an async flag, does not generalise past Claude Code, and every agent added in this phase would stall the user for the duration of speech. Do not take the shortcut.

**2. The Windows BOM bug is a category, not a one-off.** You already work around [openai/codex#23784](https://github.com/openai/codex/issues/23784) in `lib/json-get.mjs`, which strips a BOM before parsing. Cursor has the **same class of bug**, confirmed by staff on 2026-07-27: hook stdin on Windows is prefixed with `﻿`, breaking `JSON.parse`, with the vulnerable pattern present in Cursor's own documentation. Gemini has a related risk in `hookRunner.ts`, which accumulates stdout without a `StringDecoder`, so a multi-byte UTF-8 sequence split across a chunk boundary corrupts.

That means **`lib/json-get.mjs` is not a Codex workaround, it is a portable hardening layer**, and it is one of the more valuable things in the repo. Promote it in Phase 1 to the standard input path for every agent, document it as such, and say so in the README. Handling a whole class of vendor bug that the vendors themselves ship broken examples for is a credible reason to pick your tool over a competitor's.

**Rules for adding one:**

1. Verify the hook contract against the vendor's docs before writing code, exactly as was done for Codex (`README.md:93-101`). Cite the source in the PR.
2. It must be in `data/agents.json`, not in code.
3. It ships with a transcript fixture in `test/fixtures/` and a `register.mjs` test.
4. Document the degradation mode honestly, as the Kimi transcript-format note does (`README.md:113-121`). That candour is an asset. Keep it.

The Kimi transcript-recovery path and the Codex malformed-JSON workaround ([openai/codex#23784](https://github.com/openai/codex/issues/23784)) are genuinely rare engineering. **Say so in the README.** They are currently buried in prose at lines 103 to 121 where nobody reads them.

**Phase 6 acceptance:** six agents supported, each with a fixture test, and adding a seventh is a data change plus one handler.

---

# 8. Phase 7: distribution

Git-clone-only means zero adoption regardless of quality. voicemode and echook are both in the plugin marketplace. Currently you are invisible.

| Channel | Work | Why |
|---|---|---|
| **Claude Code plugin marketplace** | `.claude-plugin/plugin.json`, marketplace entry | Where the audience actually is. Do this first. |
| **npm** | `npx agent-voice install` | Node is guaranteed present. Removes the clone step entirely. |
| **Homebrew tap** | formula in `HalbonLabs/homebrew-tap` | Expected on macOS. |
| **winget** | manifest | You are Windows-first. Own that. |
| **GitHub Releases** | tagged, with a changelog and a checksum | Blocks REMEDIATION R-21 and R-22 otherwise. |

Alongside it, and more important than any of the packaging:

- **A 20-second audio sample in the README.** For a tool whose value is audible, this outweighs the current 419 lines of prose.
- **An asciinema recording** of install to first spoken reply.
- **A side-by-side clip** of a model claiming success while agent-voice says the tests are red. That is the whole pitch in eight seconds, and it is the thing people will share.

---

# 9. Where this lands

| Capability | agent-voice today | after this plan | echook | ktaletsk | voicemode |
|---|:---:|:---:|:---:|:---:|:---:|
| Deterministic (hook, not tool call) | yes | yes | yes | yes | no |
| Agents supported | 3 | 8 | 3 | 1 | 1+MCP |
| Windows first-class | partial | yes | yes | partial | partial |
| Local, no network | yes | yes | no | yes | optional |
| Warm daemon | yes | yes | no | no | yes |
| Time to first sound | ~2.7 s | <0.25 s | ~1 s | ~13 s | n/a |
| **Verified facts, not self-report** | **no** | **yes** | no | no | no |
| **Contradiction detection** | **no** | **yes** | no | no | no |
| Intent earcons | no | yes | partial | no | no |
| Attention policy | no | yes | snooze only | no | n/a |
| Multi-session arbitration | manual | yes | no | no | no |
| Desktop notification | no | yes | yes | no | no |
| Phone push | no | yes | yes | no | no |
| Distributed as a plugin | no | yes | yes | no | yes |

The two bolded rows are the ones that matter. Everything else on this list is catch-up or table stakes, and any competitor could add them in a weekend. Grounded, contradiction-checked summaries are a genuine architectural advantage of the hook position, and they are the only line here that is hard to copy.

---

# 10. Sequencing

```
REMEDIATION R-01 .. R-10          prerequisite, ~2 days with tests
   |
Phase 1  Node core                ~3-5 days   UNLOCK: halves the cost of everything below
   |
Phase 2  Grounded summaries       ~3 days     FLAGSHIP: ship this and talk about it
Phase 3  Intent + attention       ~2 days     makes it survivable past week two
   |
Phase 7  Distribution (partial)   ~1 day      plugin manifest + npm + audio sample
   |     <- earliest sensible public announcement is here
Phase 4  Latency                  ~2 days
Phase 5  Reach                    ~2 days
Phase 6  Agent breadth            ~1 day per agent
Phase 7  Distribution (rest)      ~1 day
```

Roughly three to four focused weeks.

**Announce after Phase 3 plus the plugin manifest, not before.** Phases 4 through 6 are refinements you can ship into an audience. Phases 1 through 3 are the reason anyone would want it.

## The honest risk

The digest niche may simply be small. Star counts in the competitive set are 78, 18, 16 and 2. Most people either read the last paragraph of the reply, or put "be concise, lead with what changed" in `CLAUDE.md` and get a large fraction of the benefit with zero install.

Phase 2 is the answer to that objection and the only real answer available. "Be concise" cannot tell you the model is lying about the tests. Nothing in a prompt can, because the model writing the summary is the same model that just decided the work was done. Only something outside the conversation can check.

If Phase 2 lands and it still does not find users, the niche is genuinely small and that is worth knowing after three weeks rather than three months. If it does land, it is the only tool in the category that tells you the truth, and that is a durable position.
