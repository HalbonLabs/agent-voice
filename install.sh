#!/usr/bin/env bash
# agent-voice installer (macOS). Interactive: choose agents and a voice engine.
# Run:  bash install.sh
# shellcheck disable=SC2034  # sel_* variables are read indirectly via eval (bash 3.2 has no associative arrays)
set -e

# Linux is refused, not half-installed: every playback call in the hooks is
# afplay with `say` as the fallback, so on Linux the install would complete
# cheerfully and every reply would be silent forever with no error shown.
# That is the worst failure mode a voice tool can have (R-10).
if [ "$(uname -s)" != "Darwin" ]; then
  echo "agent-voice: this installer supports macOS only (Windows has install.ps1)." >&2
  echo "Linux is not supported yet because audio playback is macOS-specific;" >&2
  echo "it is planned as part of the cross-platform core rewrite. Follow or file" >&2
  echo "an issue at https://github.com/HalbonLabs/agent-voice/issues" >&2
  exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/.agent-voice"
STATE="$TARGET/state"

AV_VERSION="$(cat "$SRC/VERSION" 2>/dev/null || echo unknown)"

echo ""
echo "agent-voice installer ($AV_VERSION)"
echo "---------------------"

if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: node not found on PATH. Node ships with these agents; install it first."
  exit 1
fi

# Copy runtime files.
mkdir -p "$STATE" "$TARGET/lib"
# Owner-only: the Kokoro port file in here carries the daemon token.
chmod 700 "$STATE"
cp -f "$SRC/core/macos/"* "$TARGET/"
cp -f "$SRC/core/"kokoro*.py "$TARGET/"
cp -f "$SRC/lib/"* "$TARGET/lib/"
# The Node core: the two hooks, the command surface, and their shared data.
rm -rf "$TARGET/src" "$TARGET/data"
cp -R "$SRC/src" "$TARGET/src"
cp -R "$SRC/data" "$TARGET/data"
cp -f "$SRC/VERSION" "$TARGET/VERSION" 2>/dev/null || true
chmod +x "$TARGET"/*.sh
echo "Installed scripts to $TARGET"

# Choose agents. Detect what is actually on this machine, and what is already
# wired up, so the list offers real choices instead of three names to recognise.
KEYS="claude codex kimi"
name_of()      { case "$1" in claude) echo "Claude Code";; codex) echo "Codex CLI";; kimi) echo "Kimi Code CLI";; esac; }
note_of()      { case "$1" in
                   claude) echo "fully supported (summary + voice)";;
                   codex)  echo "fully supported (summary + voice)";;
                   kimi)   echo "supported (summary + voice) via its session transcript";;
                 esac; }
dir_of()       { case "$1" in claude) echo "$HOME/.claude";; codex) echo "$HOME/.codex";; kimi) echo "$HOME/.kimi-code";; esac; }
cfg_of()       { case "$1" in
                   claude) echo "$HOME/.claude/settings.json";;
                   codex)  echo "$HOME/.codex/hooks.json";;
                   kimi)   echo "$HOME/.kimi-code/config.toml";;
                 esac; }
# Installed means the command is runnable, nothing weaker. The config directory
# is NOT evidence: hooks only ever fire from inside a running agent, so an agent
# whose binary is absent cannot use agent-voice no matter what it left on disk.
# This used to be `command -v ... || [ -d "$(dir_of ...)" ]`, which reported
# Codex and Kimi as installed on any machine carrying a stale (or foreign) ~/.codex
# or ~/.kimi-code, and so offered them untagged in the checklist.
is_installed()  { command -v "$1" >/dev/null 2>&1; }
# Configured-but-absent is still worth SAYING — it usually means the agent was
# installed once, or lives somewhere off PATH — so it gets its own tag rather
# than being silently folded into "installed" or into "not detected".
has_config()    { [ -d "$(dir_of "$1")" ]; }
is_registered() { [ -f "$(cfg_of "$1")" ] && grep -q 'agent-voice' "$(cfg_of "$1")" 2>/dev/null; }

# One place decides the label, so the piped and interactive lists cannot drift.
status_tag_of() {
  if is_registered "$1"; then printf 'already set up'
  elif is_installed "$1"; then printf ''
  elif has_config "$1"; then printf 'config found, but not on PATH'
  else printf 'not detected on this machine'
  fi
}

# Pre-tick anything already set up, plus Claude when it is genuinely present.
sel_claude=0; sel_codex=0; sel_kimi=0
for k in $KEYS; do
  if is_registered "$k" || { [ "$k" = "claude" ] && is_installed "$k"; }; then eval "sel_$k=1"; fi
done
get_sel() { eval "echo \$sel_$1"; }
selected_csv() { out=""; for k in $KEYS; do [ "$(get_sel "$k")" = "1" ] && out="${out:+$out,}$k"; done; printf '%s' "$out"; }

any_installed=0
for k in $KEYS; do is_installed "$k" && any_installed=1; done
echo ""
[ "$any_installed" = 0 ] && echo "None of the supported agents were detected, so all are listed."

if [ ! -t 0 ]; then
  # Not a real terminal (piped input, CI): ReadKey-style UI cannot work.
  echo "Which agents should use agent-voice? (comma-separated)"
  for k in $KEYS; do
    t="$(status_tag_of "$k")"; tag=""; [ -n "$t" ] && tag="  [$t]"
    printf '  %-8s %-16s %s%s\n' "$k" "$(name_of "$k")" "$(note_of "$k")" "$tag"
  done
  printf "Agents (Enter for claude): "
  read -r agents
  [ -z "$agents" ] && agents="claude"
else
  echo "Which agents should use agent-voice?"
  echo "Up/Down to move, Space to toggle, A for all, Enter to confirm."
  echo ""
  pos=0; count=0
  for k in $KEYS; do count=$((count + 1)); done
  first_draw=1
  while :; do
    [ "$first_draw" = 1 ] || printf '\033[%dA' "$((count + 1))"
    first_draw=0
    i=0
    for k in $KEYS; do
      if [ "$i" = "$pos" ]; then cur=">"; else cur=" "; fi
      if [ "$(get_sel "$k")" = "1" ]; then box="[x]"; else box="[ ]"; fi
      t="$(status_tag_of "$k")"; tag=""; [ -n "$t" ] && tag="  ($t)"
      printf '\033[K%s %s %-16s %s%s\n' "$cur" "$box" "$(name_of "$k")" "$(note_of "$k")" "$tag"
      i=$((i + 1))
    done
    csv="$(selected_csv)"
    printf '\033[K  selected: %s\n' "${csv:-none yet}"

    IFS= read -rsn1 ch
    if [ "$ch" = "$(printf '\033')" ]; then
      IFS= read -rsn2 -t 0.1 rest
      case "$rest" in
        '[A') pos=$(((pos - 1 + count) % count)) ;;
        '[B') pos=$(((pos + 1) % count)) ;;
      esac
      continue
    fi
    case "$ch" in
      ' ')
        i=0
        for k in $KEYS; do
          if [ "$i" = "$pos" ]; then
            if [ "$(get_sel "$k")" = "1" ]; then eval "sel_$k=0"; else eval "sel_$k=1"; fi
          fi
          i=$((i + 1))
        done ;;
      a|A)
        allon=1
        for k in $KEYS; do [ "$(get_sel "$k")" = "1" ] || allon=0; done
        for k in $KEYS; do if [ "$allon" = "1" ]; then eval "sel_$k=0"; else eval "sel_$k=1"; fi; done ;;
      '')
        agents="$(selected_csv)"
        if [ -n "$agents" ]; then echo ""; break; fi ;;
    esac
  done
fi
echo "Agents: $agents"

# --- Python resolution -------------------------------------------------------
#
# Two things went wrong here before, and they compound, so both are fixed together.
#
# 1. VERSION. The old check asked only "is this Python 3", which any 3.x passes.
#    On a stock Mac bare `python3` is /usr/bin/python3 = 3.9, and Kokoro pulls
#    spacy, which needs thinc >= 8.3.12, which needs Python >= 3.10. So pip
#    correctly reported "No matching distribution found for thinc" and the whole
#    install died. Kokoro was never installable on a default macOS.
#
# 2. PEP 668. Simply pointing at a newer interpreter trades that error for a
#    different one: Homebrew's pythons ship an EXTERNALLY-MANAGED marker, so
#    `pip install --user` refuses outright. The one interpreter that ACCEPTS
#    --user on a stock Mac is the 3.9 that is too old to use.
#
# A private venv resolves both: it is never externally managed, it cannot be
# broken by the user's other Python work, and it gives the hooks one unambiguous
# interpreter to record in config.
VENV="$TARGET/venv"

# Kokoro's window is bounded at BOTH ends, by its own package metadata:
# every current release (0.8.1 through 0.9.4) declares
#
#     Requires-Python >=3.10,<3.13
#
# so 3.10, 3.11 and 3.12 are the whole supported set. Verified on 2026-08-10 by
# installing successfully on 3.12 and watching 3.9 and 3.13 both fail.
#
# The 3.13 failure is worth knowing because it does not look like a version
# problem. pip ignores every modern kokoro (all excluded by that constraint),
# backtracks to ancient 0.7.x releases, and those pin numpy==1.26.4, which has no
# wheels above cp312 — so it dies part-way through a source build of the
# spacy/blis stack with no mention of Python versions at all. A floor-only check
# lets that through. edge-tts is pure Python and has no ceiling.
PY_MIN_EDGE="3.9";    PY_MAX_EDGE=""
PY_MIN_KOKORO="3.10"; PY_MAX_KOKORO="3.12"

# First interpreter within [$1, $2]. $2 empty means no upper bound. Candidates are
# swept newest-first WITHIN the window, so a machine carrying both 3.12 and 3.11
# gets 3.12, and one carrying only 3.13 correctly reports nothing usable rather
# than handing back an interpreter that will fail during pip.
find_python() {
  want_maj="${1%%.*}"; want_min="${1##*.}"
  if [ -n "${2:-}" ]; then max_maj="${2%%.*}"; max_min="${2##*.}"; else max_maj=99; max_min=99; fi
  for c in python3.13 python3.12 python3.11 python3.10 \
           python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    p="$(command -v "$c" 2>/dev/null)" || continue
    [ -n "$p" ] && [ -x "$p" ] || continue
    if "$p" -c "import sys; sys.exit(0 if ($want_maj, $want_min) <= sys.version_info[:2] <= ($max_maj, $max_min) else 1)" >/dev/null 2>&1; then
      printf '%s' "$p"; return 0
    fi
  done
  return 1
}

# Create (or reuse) the private environment and print its interpreter.
# Prints nothing and returns non-zero if it cannot be built, so every caller
# must branch rather than silently carrying on with a broken path.
ensure_venv() {
  base="$1"
  if [ ! -x "$VENV/bin/python" ]; then
    echo "Creating a private Python environment in $VENV ..." >&2
    "$base" -m venv "$VENV" >/dev/null 2>&1 || return 1
  fi
  [ -x "$VENV/bin/python" ] || return 1
  "$VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
  printf '%s' "$VENV/bin/python"
}

# Resolve an interpreter within [$1, $2] and return a venv built on it.
python_for() {
  base="$(find_python "$1" "${2:-}")" || return 1
  ensure_venv "$base" || return 1
}

# macOS has no scriptable global-hotkey API, so a shortcut cannot simply be
# registered the way Ctrl+Alt+S is on Windows. What can be done is build the Quick
# Action for you, leaving only the key assignment, which is two clicks in System
# Settings. Typing 'voice stop' in a session needs no setup at all and is the
# fallback if this does not appear.
install_mac_quick_action() {
  [ "$(uname)" = "Darwin" ] || return 0
  qa="$HOME/Library/Services/Stop agent-voice.workflow"
  mkdir -p "$qa/Contents" 2>/dev/null || return 0

  # $TARGET is interpolated into XML below; a home directory containing &, <,
  # or a quote would otherwise produce a malformed workflow that fails with no
  # error shown (R-20).
  TARGET_XML="$(printf '%s' "$TARGET" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g")"

  cat > "$qa/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict>
        <key>default</key>
        <string>Stop agent-voice</string>
      </dict>
      <key>NSMessage</key>
      <string>runWorkflowAsService</string>
      <key>NSSendTypes</key>
      <array/>
      <key>NSReturnTypes</key>
      <array/>
    </dict>
  </array>
</dict>
</plist>
PLIST

  cat > "$qa/Contents/document.wflow" <<WFLOW
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AMApplicationBuild</key>
  <string>512</string>
  <key>AMApplicationVersion</key>
  <string>2.10</string>
  <key>AMDocumentVersion</key>
  <string>2</string>
  <key>actions</key>
  <array>
    <dict>
      <key>action</key>
      <dict>
        <key>AMActionVersion</key>
        <string>2.0.3</string>
        <key>ActionBundlePath</key>
        <string>/System/Library/Automator/Run Shell Script.action</string>
        <key>ActionName</key>
        <string>Run Shell Script</string>
        <key>ActionParameters</key>
        <dict>
          <key>COMMAND_STRING</key>
          <string>bash "$TARGET_XML/shush.sh"</string>
          <key>CheckedForUserDefaultShell</key>
          <true/>
          <key>inputMethod</key>
          <integer>0</integer>
          <key>shell</key>
          <string>/bin/bash</string>
          <key>source</key>
          <string></string>
        </dict>
        <key>BundleIdentifier</key>
        <string>com.apple.Automator.RunShellScript</string>
        <key>Class Name</key>
        <string>RunShellScriptAction</string>
        <key>InputUUID</key>
        <string>7E4F1A20-0001-4A00-9000-AGENTVOICE01</string>
        <key>OutputUUID</key>
        <string>7E4F1A20-0002-4A00-9000-AGENTVOICE02</string>
        <key>UUID</key>
        <string>7E4F1A20-0003-4A00-9000-AGENTVOICE03</string>
        <key>arguments</key>
        <dict/>
        <key>isViewVisible</key>
        <integer>1</integer>
      </dict>
    </dict>
  </array>
  <key>workflowMetaData</key>
  <dict>
    <key>serviceInputTypeIdentifier</key>
    <string>com.apple.Automator.nothing</string>
    <key>serviceOutputTypeIdentifier</key>
    <string>com.apple.Automator.nothing</string>
    <key>serviceApplicationBundleID</key>
    <string></string>
    <key>serviceApplicationPath</key>
    <string></string>
    <key>presentationMode</key>
    <integer>0</integer>
    <key>processesInput</key>
    <integer>0</integer>
    <key>workflowTypeIdentifier</key>
    <string>com.apple.Automator.servicesMenu</string>
  </dict>
</dict>
</plist>
WFLOW

  # Ask the services system to notice the new Quick Action straight away.
  /System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true

  echo ""
  echo "Stop-speech Quick Action installed. To give it a hotkey (about 20 seconds):"
  echo "  System Settings > Keyboard > Keyboard Shortcuts > Services > General"
  echo "  find 'Stop agent-voice', click 'none', and press the keys you want."
  echo "  Cmd+Alt+S is a good choice, to match Ctrl+Alt+S on Windows."
  echo "If it does not appear, just type 'voice stop' in any session instead."
}

# Shared message for the two engines that need Python. Falling back to native is
# stated out loud rather than done quietly, so nobody ends up wondering why the
# voice sounds robotic.
# $1 = engine, $2 = minimum, $3 = maximum ("" for none). Naming the actual window
# is the point: the old wording said only "Python 3 was not found on PATH", which
# is actively misleading on a Mac that HAS python3 and simply has the wrong one.
# It is equally misleading to say "or newer" for an engine with a ceiling — that
# is what sends someone to install 3.14 and hit a stranger failure.
deny_python_engine() {
  echo ""
  if [ -n "${3:-}" ]; then
    echo "$1 needs Python between $2 and $3, and no interpreter in that range was found."
  else
    echo "$1 needs Python $2 or newer, and no interpreter that new was found."
  fi
  if [ "$(uname)" = "Darwin" ]; then
    echo "  macOS ships Python 3.9 at /usr/bin/python3, which is below the floor."
    if [ -n "${3:-}" ]; then
      echo "  Newer is not automatically better here: $1 pins dependencies that publish"
      echo "  no wheels above $3, so 3.13 and 3.14 fail too."
      echo "  Install one in range with:  brew install python@$3"
    else
      echo "  Install a newer one with:  brew install python@3.13"
    fi
    echo "  (or from https://www.python.org/downloads/)"
  else
    if [ -n "${3:-}" ]; then
      echo "  Install one in range, e.g.:  sudo apt-get install python$3 python$3-venv"
    else
      echo "  Install one with:  sudo apt-get install python3 python3-venv python3-pip"
    fi
  fi
  echo "  Then run this installer again and pick that engine."
  echo "Using Native offline for now, so you still get a working voice."
}

# Shown when an interpreter IS new enough but the environment could not be built.
deny_venv() {
  echo ""
  echo "$1 needs a private Python environment and one could not be created at $VENV."
  if [ "$(uname)" = "Darwin" ]; then
    echo "  Check that the venv module is present:  $(find_python "$2" 2>/dev/null || echo python3) -m venv --help"
  else
    echo "  On Debian/Ubuntu this usually means:  sudo apt-get install python3-venv"
  fi
  echo "Using Native offline for now, so you still get a working voice."
}

# Kokoro's voices come from lib/kokoro-voices.json, the same file the hooks read for
# "voice list" and for validating "voice model", so the ids and the published quality
# grades cannot drift between what you can install and what you can switch to.
KOKORO_VOICES=()
while IFS= read -r line; do KOKORO_VOICES+=("$line"); done < <(
  node -e 'for (const v of require(process.argv[1])) console.log(`${v.id}|${v.lang}|${v.sex}|${v.grade}`)' \
    "$SRC/lib/kokoro-voices.json"
)
# The voice picker (arrow keys, P to preview) lives in core/macos/pick-voice.sh so
# that the installer and the in-session "voice pick" command share one
# implementation rather than drifting apart.
. "$SRC/core/macos/pick-voice.sh"
# Choose engine.
echo ""
echo "Choose a voice engine:"
echo "  [1] edge-tts (Ava)   Free, natural. Short summary text sent to Microsoft. Needs Python 3. Quality: very good."
echo "  [2] ElevenLabs       Top quality. Uses your API key; summary text sent to ElevenLabs. Quality: best."
echo "  [3] Kokoro offline   Free, natural, fully private. Needs Python 3 + ~300MB weights. Quality: good."
echo "  [4] Native offline   Fully private, no downloads, nothing to install. Uses macOS 'say'. Quality: robotic."
echo ""
printf "Enter 1, 2, 3, or 4: "
read -r choice

CFG="$TARGET/config"; : > "$CFG"
case "$choice" in
  2)
    echo "engine=elevenlabs" >> "$CFG"
    printf "Paste your ElevenLabs API key: "
    stty -echo; read -r key; stty echo; echo ""
    printf '%s' "$key" > "$TARGET/elevenlabs-key"; chmod 600 "$TARGET/elevenlabs-key"
    printf 'Voice ID (Enter for default British male "George"): '
    read -r vid; [ -z "$vid" ] && vid="JBFqnCBsd6RMkjVDRZzb"
    echo "eleven_voice=$vid" >> "$CFG"
    echo "eleven_model=eleven_flash_v2_5" >> "$CFG"
    echo "ElevenLabs selected. Key stored locally (not in any script)."
    ;;
  3)
    if ! find_python "$PY_MIN_KOKORO" "$PY_MAX_KOKORO" >/dev/null 2>&1; then
      deny_python_engine "Kokoro" "$PY_MIN_KOKORO" "$PY_MAX_KOKORO"
      echo "engine=native" >> "$CFG"
    elif ! PYX="$(python_for "$PY_MIN_KOKORO" "$PY_MAX_KOKORO")"; then
      deny_venv "Kokoro" "$PY_MIN_KOKORO"
      echo "engine=native" >> "$CFG"
    else
      echo "Kokoro offline selected. Nothing will leave this machine."
      echo "Using $("$PYX" -c 'import sys;print("Python "+".".join(map(str,sys.version_info[:3])))') in $VENV"
      echo "Kokoro keeps a warm background process so replies start speaking in ~1.7s."
      echo "It uses about 1.7GB of RAM while resident, and exits after 15 idle minutes."

      # Dependencies and the model come first, so that voice previews are quick when
      # you get to the list rather than costing ten seconds each.
      # espeak-ng is not required: the espeakng-loader dependency bundles it.
      # Installed INTO the venv, never with --user: Homebrew pythons are PEP 668
      # externally managed and refuse --user outright.
      if ! "$PYX" -c 'import kokoro, soundfile' >/dev/null 2>&1; then
        echo "Installing Kokoro into $VENV ... this pulls in PyTorch and takes a few minutes."
        if ! "$PYX" -m pip install kokoro soundfile; then
          echo ""
          echo "Kokoro's dependencies would not install. Falling back to the basic 'say' voice."
          echo "The error above is the real one; rerun with a different Python if it mentions a version."
          echo "engine=native" >> "$CFG"
          break_kokoro=1
        fi
      fi

      if [ "${break_kokoro:-0}" != 1 ]; then
      # Warm up: pre-download the weights and the spaCy model that Kokoro's text
      # front-end fetches on first use, so the first spoken reply is not silent.
      echo "Downloading Kokoro voice weights (~300MB) and language model (one time) ..."
      probe="$STATE/warmup.wav"
      printf 'agent voice is ready' | "$PYX" "$TARGET/kokoro-tts.py" "$probe" "bf_emma" 1.15 || true
      kokoro_works=0
      if [ -s "$probe" ] && [ "$(wc -c < "$probe")" -gt 500 ]; then kokoro_works=1; fi
      rm -f "$probe"

      if [ "$kokoro_works" = 1 ]; then
        echo "Kokoro is working."
        echo ""
        # Hand the picker the interpreter we just verified. Config is not written
        # until below, so without this the previews resolve bare python3.
        PICK_PY="$PYX" export PICK_PY
        select_voice "bf_emma"
        kv="$chosen_voice"
      else
        echo "Kokoro could not synthesise yet. Voice will use the basic 'say' voice until this is fixed;"
        echo "run  $PYX -m pip install kokoro soundfile  by hand to see the error."
        kv="bf_emma"
      fi

      echo "engine=kokoro" >> "$CFG"
      echo "kokoro_voice=$kv" >> "$CFG"
      echo "kokoro_speed=1.15" >> "$CFG"
      echo "python_cmd=$PYX" >> "$CFG"
      echo "Voice: $kv"
      fi
    fi
    ;;
  4)
    echo "engine=native" >> "$CFG"
    echo "Native offline selected (macOS 'say'). Add premium voices in System Settings > Accessibility > Spoken Content."
    ;;
  *)
    if ! find_python "$PY_MIN_EDGE" "$PY_MAX_EDGE" >/dev/null 2>&1; then
      deny_python_engine "edge-tts" "$PY_MIN_EDGE" "$PY_MAX_EDGE"
      echo "engine=native" >> "$CFG"
    elif ! PYX="$(python_for "$PY_MIN_EDGE" "$PY_MAX_EDGE")"; then
      deny_venv "edge-tts" "$PY_MIN_EDGE"
      echo "engine=native" >> "$CFG"
    else
      echo "engine=edge" >> "$CFG"
      echo "edge_voice=en-US-AvaNeural" >> "$CFG"
      echo "edge_rate=+15%" >> "$CFG"
      echo "python_cmd=$PYX" >> "$CFG"
      echo "edge-tts (Ava) selected."
      # Into the venv, not --user — see the PEP 668 note above python resolution.
      if ! "$PYX" -m edge_tts --version >/dev/null 2>&1; then
        echo "Installing edge-tts into $VENV ..."
        "$PYX" -m pip install edge-tts || true
      fi
      # Confirm it can actually speak, rather than assuming pip succeeded.
      if ! "$PYX" -m edge_tts --version >/dev/null 2>&1; then
        echo "edge-tts still is not working, so replies will use the basic 'say' voice."
        echo "Run  $PYX -m pip install edge-tts  by hand to see the error."
      fi
    fi
    ;;
esac

# Speak on problems by default, not on every turn: the earcon still marks
# every turn's intent, and 'voice when always' is one command away (P3-2).
echo "voice_when=problem" >> "$CFG"

# Global default ON so it works immediately.
: > "$STATE/voice-on"
echo ""
echo "Speech policy: speaks only for question / blocked / failed turns; a short"
echo "tone marks every other turn. Type 'voice when always' in a session for"
echo "speech on every turn, or 'voice when' to see the options."

# Register hooks into the chosen agents.
echo ""
node "$TARGET/lib/register.mjs" mode=install home="$HOME" platform=mac scripts="$TARGET" providers="$agents"

install_mac_quick_action

echo ""
echo "Done."
echo "Reload any open agent session so it picks up the hooks."
echo "In any session, type:  voice on  |  voice text  |  voice off  |  voice status"
echo "Also per session:  voice engine  |  voice model  |  voice speed  |  voice list"
echo "Forgotten one? Type:  voice help"
echo "Stop speech anytime:   type  voice stop  in any session, or run  $TARGET/shush.sh"
