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

echo ""
echo "agent-voice installer"
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
is_installed()  { command -v "$1" >/dev/null 2>&1 || [ -d "$(dir_of "$1")" ]; }
is_registered() { [ -f "$(cfg_of "$1")" ] && grep -q 'agent-voice' "$(cfg_of "$1")" 2>/dev/null; }

# Pre-tick anything already set up, plus Claude when it is present.
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
    tag=""
    is_installed "$k" || tag="  [not detected]"
    is_registered "$k" && tag="  [already set up]"
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
      tag=""
      is_installed "$k" || tag="  (not detected on this machine)"
      is_registered "$k" && tag="  (already set up)"
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

# Kokoro declares Requires-Python >=3.10,<3.13. An interpreter that is too NEW
# is rejected as firmly as one too old: on 3.13, pip falls back to building
# blis/thinc from source, which fails deep inside the install with an error
# that looks nothing like a version problem.
PY_MIN_EDGE="3.9"
PY_MIN_KOKORO="3.10"
PY_MAX_KOKORO="3.12"

# py_in_range CMD MIN MAX: the interpreter bounds-checks itself ("" = no max).
py_in_range() {
  "$1" -c '
import sys
def parse(s):
    p = s.split("."); return (int(p[0]), int(p[1]) if len(p) > 1 else 0)
lo = parse(sys.argv[1]); hi = sys.argv[2]
v = tuple(sys.version_info[:2])
sys.exit(0 if v >= lo and (not hi or v <= parse(hi)) else 1)
' "$2" "$3" >/dev/null 2>&1
}

# find_python MIN MAX: sweep newest-allowed-first and print the interpreter's
# full path. Recording the path matters because the hooks run with whatever
# PATH the launching agent has, which may put a project venv first.
find_python() {
  for cand in python3.12 python3.11 python3.10 python3 python; do
    command -v "$cand" >/dev/null 2>&1 || continue
    py_in_range "$cand" "$1" "$2" || continue
    "$cand" -c 'import sys; print(sys.executable)' 2>/dev/null
    return 0
  done
  return 1
}

# The dependencies live in a private venv at ~/.agent-voice/venv, not in --user
# site-packages: PEP 668 Pythons (Homebrew, Debian) refuse --user outright, and
# a shared site bleeds into and from project environments. python_cmd in the
# config points into the venv, so the hooks always find what was installed.
setup_venv() {  # setup_venv BASE_PYTHON -> prints the venv interpreter path
  vdir="$TARGET/venv"; vpy="$vdir/bin/python"
  if [ ! -x "$vpy" ]; then
    echo "Creating private environment at $vdir ..." >&2
    "$1" -m venv "$vdir" >&2 || return 1
  fi
  [ -x "$vpy" ] || return 1
  printf '%s' "$vpy"
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
          <string>bash "$TARGET/shush.sh"</string>
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
# voice sounds robotic. Names the accepted range: the instinct on a version
# error is to install the newest Python, which for Kokoro makes it worse.
deny_python_engine() {  # deny_python_engine ENGINE RANGE_TEXT
  echo ""
  echo "No usable Python for $1 was found. It needs $2."
  echo "  Install one with:  brew install python@3.12     (or from https://www.python.org/downloads/)"
  echo "  Note: a NEWER Python does not help; the range really is $2."
  echo "  Then run this installer again and pick that engine."
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
    base_py="$(find_python "$PY_MIN_KOKORO" "$PY_MAX_KOKORO")" || base_py=""
    vpy=""
    [ -n "$base_py" ] && vpy="$(setup_venv "$base_py")"
    if [ -z "$base_py" ]; then
      deny_python_engine "Kokoro" "Python 3.10 to 3.12"
      echo "engine=native" >> "$CFG"
    elif [ -z "$vpy" ]; then
      echo "Could not create the private environment (using $base_py). Falling back to Native offline."
      echo "engine=native" >> "$CFG"
    else
      echo "Kokoro offline selected. Nothing will leave this machine."
      echo "Kokoro keeps a warm background process so replies start speaking in ~1.7s."
      echo "It uses about 1.7GB of RAM while resident, and exits after 15 idle minutes."

      # Dependencies and the model come first, so that voice previews are quick when
      # you get to the list rather than costing ten seconds each.
      # espeak-ng is not required: the espeakng-loader dependency bundles it.
      kokoro_deps=1
      if ! "$vpy" -c 'import kokoro, soundfile' >/dev/null 2>&1; then
        echo "Installing Kokoro into the private environment ... this pulls in PyTorch and takes a few minutes."
        if ! "$vpy" -m pip install kokoro soundfile; then
          echo "The Kokoro install FAILED (see pip output above)."
          echo "Re-run this installer after fixing it. Environment: $vpy"
          kokoro_deps=0
        fi
      fi

      if [ "$kokoro_deps" = 0 ]; then
        echo "engine=native" >> "$CFG"
      else
        # Warm up: pre-download the weights and the spaCy model that Kokoro's text
        # front-end fetches on first use, so the first spoken reply is not silent.
        echo "Downloading Kokoro voice weights (~300MB) and language model (one time) ..."
        probe="$STATE/warmup.wav"
        printf 'agent voice is ready' | "$vpy" "$TARGET/kokoro-tts.py" "$probe" "bf_emma" 1.15 || true
        kokoro_works=0
        if [ -s "$probe" ] && [ "$(wc -c < "$probe")" -gt 500 ]; then kokoro_works=1; fi
        rm -f "$probe"

        if [ "$kokoro_works" = 1 ]; then
          echo "Kokoro is working."
          echo ""
          # pick-voice.sh was sourced before the config exists, so its pick_py
          # resolved to bare python3; point previews at the venv we just built.
          pick_py="$vpy"
          select_voice "bf_emma"
          kv="$chosen_voice"
        else
          echo "Kokoro could not synthesise yet. Voice will use the basic 'say' voice until this is fixed;"
          echo "run  $vpy -m pip install kokoro soundfile  by hand to see the error."
          kv="bf_emma"
        fi

        echo "engine=kokoro" >> "$CFG"
        echo "kokoro_voice=$kv" >> "$CFG"
        echo "kokoro_speed=1.15" >> "$CFG"
        echo "python_cmd=$vpy" >> "$CFG"
        echo "Voice: $kv"
      fi
    fi
    ;;
  4)
    echo "engine=native" >> "$CFG"
    echo "Native offline selected (macOS 'say'). Add premium voices in System Settings > Accessibility > Spoken Content."
    ;;
  *)
    base_py="$(find_python "$PY_MIN_EDGE" "")" || base_py=""
    vpy=""
    [ -n "$base_py" ] && vpy="$(setup_venv "$base_py")"
    if [ -z "$base_py" ]; then
      deny_python_engine "edge-tts" "Python 3.9 or newer"
      echo "engine=native" >> "$CFG"
    elif [ -z "$vpy" ]; then
      echo "Could not create the private environment (using $base_py). Falling back to Native offline."
      echo "engine=native" >> "$CFG"
    else
      echo "engine=edge" >> "$CFG"
      echo "edge_voice=en-US-AvaNeural" >> "$CFG"
      echo "edge_rate=+15%" >> "$CFG"
      echo "python_cmd=$vpy" >> "$CFG"
      echo "edge-tts (Ava) selected."
      if ! "$vpy" -m edge_tts --version >/dev/null 2>&1; then
        echo "Installing edge-tts into the private environment ..."
        if ! "$vpy" -m pip install edge-tts; then
          echo "The edge-tts install FAILED (see pip output above)."
        fi
      fi
      # Confirm it can actually speak, rather than assuming pip succeeded.
      if ! "$vpy" -m edge_tts --version >/dev/null 2>&1; then
        echo "edge-tts still is not working, so replies will use the basic 'say' voice."
        echo "Run  $vpy -m pip install edge-tts  by hand to see the error."
      fi
    fi
    ;;
esac

# Global default ON so it works immediately.
: > "$STATE/voice-on"

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
