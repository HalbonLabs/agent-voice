#!/usr/bin/env bash
# agent-voice installer (macOS/Linux). Interactive: choose agents and a voice engine.
# Run:  bash install.sh
set -e

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
                   codex)  echo "supported; checked against the docs, not yet run live";;
                   kimi)   echo "summary text only; voice pending upstream support";;
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

# Does the python3 the hooks will actually call work?
have_python() {
  python3 -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1
}

# Shared message for the two engines that need Python. Falling back to native is
# stated out loud rather than done quietly, so nobody ends up wondering why the
# voice sounds robotic.
deny_python_engine() {
  echo ""
  echo "Python 3 was not found on PATH, and $1 needs it."
  if [ "$(uname)" = "Darwin" ]; then
    echo "  Install it with:  brew install python3     (or from https://www.python.org/downloads/)"
  else
    echo "  Install it with:  sudo apt-get install python3 python3-pip"
  fi
  echo "  Then run this installer again and pick that engine."
  echo "Using Native offline for now, so you still get a working voice."
}

# Kokoro's voices, with the quality grades published in the model's own VOICES.md.
# The grades vary a lot, so they are shown rather than hidden: bf_emma is the best
# British voice at B-, while every British male tops out at C.
KOKORO_VOICES=(
  "bf_emma|British|Female|B-"      "bf_isabella|British|Female|C"   "bf_alice|British|Female|D"
  "bf_lily|British|Female|D"       "bm_fable|British|Male|C"        "bm_george|British|Male|C"
  "bm_lewis|British|Male|D+"       "bm_daniel|British|Male|D"
  "af_heart|American|Female|A"     "af_bella|American|Female|A-"    "af_nicole|American|Female|B-"
  "af_aoede|American|Female|C+"    "af_kore|American|Female|C+"     "af_sarah|American|Female|C+"
  "af_alloy|American|Female|C"     "af_nova|American|Female|C"      "af_sky|American|Female|C-"
  "af_jessica|American|Female|D"   "af_river|American|Female|D"
  "am_fenrir|American|Male|C+"     "am_michael|American|Male|C+"    "am_puck|American|Male|C+"
  "am_echo|American|Male|D"        "am_eric|American|Male|D"        "am_liam|American|Male|D"
  "am_onyx|American|Male|D"        "am_santa|American|Male|D-"      "am_adam|American|Male|F+"
  "ff_siwis|French|Female|B-"
  "jf_alpha|Japanese|Female|C+"    "jf_gongitsune|Japanese|Female|C" "jf_tebukuro|Japanese|Female|C"
  "jf_nezumi|Japanese|Female|C-"   "jm_kumo|Japanese|Male|C-"
  "hf_alpha|Hindi|Female|C"        "hf_beta|Hindi|Female|C"         "hm_omega|Hindi|Male|C"
  "hm_psi|Hindi|Male|C"
  "if_sara|Italian|Female|C"       "im_nicola|Italian|Male|C"
  "zf_xiaoxiao|Mandarin|Female|D"  "zf_xiaobei|Mandarin|Female|D"   "zf_xiaoni|Mandarin|Female|D"
  "zf_xiaoyi|Mandarin|Female|D"    "zm_yunjian|Mandarin|Male|D"     "zm_yunxi|Mandarin|Male|D"
  "zm_yunxia|Mandarin|Male|D"      "zm_yunyang|Mandarin|Male|D"
  "ef_dora|Spanish|Female|-"       "em_alex|Spanish|Male|-"         "em_santa|Spanish|Male|-"
  "pf_dora|Portuguese|Female|-"    "pm_alex|Portuguese|Male|-"      "pm_santa|Portuguese|Male|-"
)

# Speak a sample in one voice. Cheap once the daemon is warm, which is why voice
# selection happens after the model has been pre-loaded.
preview_voice() {
  pv_wav="$STATE/preview.wav"
  rm -f "$pv_wav"
  printf 'This is how I will read your summaries back to you.' \
    | python3 "$TARGET/kokoro-tts.py" "$pv_wav" "$1" 1.15 >/dev/null 2>&1
  if [ -s "$pv_wav" ] && [ "$(wc -c < "$pv_wav")" -gt 500 ]; then
    afplay "$pv_wav" >/dev/null 2>&1
    rm -f "$pv_wav"
    return 0
  fi
  return 1
}

# Single-select list with a scrolling viewport and audio preview. Sets $chosen_voice.
select_voice() {
  default_voice="$1"
  total=${#KOKORO_VOICES[@]}

  if [ ! -t 0 ]; then
    printf 'Kokoro voice (Enter for British female "%s"): ' "$default_voice"
    read -r typed
    chosen_voice="${typed:-$default_voice}"
    return
  fi

  vpos=0
  i=0
  for entry in "${KOKORO_VOICES[@]}"; do
    [ "${entry%%|*}" = "$default_voice" ] && vpos=$i
    i=$((i + 1))
  done
  view=12
  [ "$total" -lt "$view" ] && view=$total
  vrows=$((view + 2))
  vstart=0
  status="Press P to hear the highlighted voice."
  pending=0
  first=1

  while :; do
    [ "$vpos" -lt "$vstart" ] && vstart=$vpos
    [ "$vpos" -ge $((vstart + view)) ] && vstart=$((vpos - view + 1))

    [ "$first" = 1 ] || printf '\033[%dA' "$vrows"
    first=0

    i=$vstart
    while [ "$i" -lt $((vstart + view)) ]; do
      entry="${KOKORO_VOICES[$i]}"
      vid="${entry%%|*}"; rest="${entry#*|}"
      vlang="${rest%%|*}"; rest="${rest#*|}"
      vsex="${rest%%|*}"; vgrade="${rest##*|}"
      if [ "$i" = "$vpos" ]; then cur=">"; else cur=" "; fi
      printf '\033[K%s %-14s %-11s %-7s grade %s\n' "$cur" "$vid" "$vlang" "$vsex" "$vgrade"
      i=$((i + 1))
    done
    printf '\033[K  showing %d-%d of %d   Up/Down to move, P to preview, Enter to choose\n' \
      "$((vstart + 1))" "$((vstart + view))" "$total"
    printf '\033[K  %s\n' "$status"

    if [ "$pending" = 1 ]; then
      pending=0
      cur_id="${KOKORO_VOICES[$vpos]%%|*}"
      if preview_voice "$cur_id"; then
        status="Played $cur_id. Press P again, or Enter to choose it."
      else
        status="Could not synthesise $cur_id. Try another."
      fi
      continue
    fi

    IFS= read -rsn1 ch
    if [ "$ch" = "$(printf '\033')" ]; then
      IFS= read -rsn2 -t 0.1 rest2
      case "$rest2" in
        '[A') vpos=$(((vpos - 1 + total) % total)) ;;
        '[B') vpos=$(((vpos + 1) % total)) ;;
      esac
      continue
    fi
    case "$ch" in
      p|P) status="Synthesising ${KOKORO_VOICES[$vpos]%%|*} ..."; pending=1 ;;
      '')  echo ""; chosen_voice="${KOKORO_VOICES[$vpos]%%|*}"; return ;;
    esac
  done
}

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
    if ! have_python; then
      deny_python_engine "Kokoro"
      echo "engine=native" >> "$CFG"
    else
      echo "Kokoro offline selected. Nothing will leave this machine."
      echo "Kokoro keeps a warm background process so replies start speaking in ~1.7s."
      echo "It uses about 1.7GB of RAM while resident, and exits after 15 idle minutes."

      # Dependencies and the model come first, so that voice previews are quick when
      # you get to the list rather than costing ten seconds each.
      # espeak-ng is not required: the espeakng-loader dependency bundles it.
      if ! python3 -c 'import kokoro, soundfile' >/dev/null 2>&1; then
        echo "Installing Kokoro (pip3 install --user kokoro soundfile) ... this pulls in PyTorch and takes a few minutes."
        python3 -m pip install --user kokoro soundfile
      fi

      # Warm up: pre-download the weights and the spaCy model that Kokoro's text
      # front-end fetches on first use, so the first spoken reply is not silent.
      echo "Downloading Kokoro voice weights (~300MB) and language model (one time) ..."
      probe="$STATE/warmup.wav"
      printf 'agent voice is ready' | python3 "$TARGET/kokoro-tts.py" "$probe" "bf_emma" 1.15 || true
      kokoro_works=0
      if [ -s "$probe" ] && [ "$(wc -c < "$probe")" -gt 500 ]; then kokoro_works=1; fi
      rm -f "$probe"

      if [ "$kokoro_works" = 1 ]; then
        echo "Kokoro is working."
        echo ""
        select_voice "bf_emma"
        kv="$chosen_voice"
      else
        echo "Kokoro could not synthesise yet. Voice will use the basic 'say' voice until this is fixed;"
        echo "run the pip3 install above by hand to see the error."
        kv="bf_emma"
      fi

      echo "engine=kokoro" >> "$CFG"
      echo "kokoro_voice=$kv" >> "$CFG"
      echo "kokoro_speed=1.15" >> "$CFG"
      echo "Voice: $kv"
    fi
    ;;
  4)
    echo "engine=native" >> "$CFG"
    echo "Native offline selected (macOS 'say'). Add premium voices in System Settings > Accessibility > Spoken Content."
    ;;
  *)
    if ! have_python; then
      deny_python_engine "edge-tts"
      echo "engine=native" >> "$CFG"
    else
      echo "engine=edge" >> "$CFG"
      echo "edge_voice=en-US-AvaNeural" >> "$CFG"
      echo "edge_rate=+15%" >> "$CFG"
      echo "edge-tts (Ava) selected."
      if ! python3 -m edge_tts --version >/dev/null 2>&1; then
        echo "Installing edge-tts (pip3 install --user edge-tts) ..."
        python3 -m pip install --user edge-tts
      fi
      # Confirm it can actually speak, rather than assuming pip succeeded.
      if ! python3 -m edge_tts --version >/dev/null 2>&1; then
        echo "edge-tts still is not working, so replies will use the basic 'say' voice."
        echo "Run 'python3 -m pip install --user edge-tts' by hand to see the error."
      fi
    fi
    ;;
esac

# Global default ON so it works immediately.
: > "$STATE/voice-on"

# Register hooks into the chosen agents.
echo ""
node "$TARGET/lib/register.mjs" mode=install home="$HOME" platform=mac scripts="$TARGET" providers="$agents"

echo ""
echo "Done."
echo "Reload any open agent session so it picks up the hooks."
echo "In any session, type:  voice on  |  voice text  |  voice off  |  voice status"
echo "Try another engine in one session only:  voice engine edge  (or kokoro/elevenlabs/native)"
echo "Stop speech anytime:   run  $TARGET/shush.sh  (bind it to a hotkey via the Shortcuts app)"
