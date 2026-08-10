#!/usr/bin/env bash
# Shared Kokoro voice picker: arrow keys to move, P to hear the highlighted voice,
# Enter to choose. Used three ways, so the installer and the in-session commands
# cannot drift apart:
#
#   1. Sourced by install.sh, which calls select_voice directly.
#   2. Run with --session <id>, opened in its own Terminal window by the
#      voice-context hook. The hook cannot do this itself: it runs
#      non-interactively with stdin carrying the JSON payload, so it has no
#      keyboard to read.
#   3. Run with --preview <id> to play one voice and exit, used by "voice preview".

ROOT="${ROOT:-$HOME/.agent-voice}"
TARGET="$ROOT"
STATE="$ROOT/state"

cfg_read() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ROOT/config" 2>/dev/null | tail -1; }

# Resolved at USE time, not at source time. install.sh sources this file before it
# writes the config, so a file-scope read here returned empty and fell back to bare
# python3 — which on a Mac is the system 3.9 that has no kokoro in it. Every preview
# in the installer then failed the >500 byte check and played nothing, silently.
# $PICK_PY lets install.sh hand in the interpreter it just built the venv around.
resolve_pick_py() {
  if [ -n "${PICK_PY:-}" ]; then printf '%s' "$PICK_PY"; return 0; fi
  p="$(cfg_read python_cmd)"; [ -z "$p" ] && p="$(cfg_read kokoro_python)"
  [ -z "$p" ] && p="python3"
  printf '%s' "$p"
}

# Speak a sample in one voice. Cheap once the daemon is warm, which is why voice
# selection happens after the model has been pre-loaded.
preview_voice() {
  pv_wav="$STATE/preview.wav"
  rm -f "$pv_wav"
  printf 'This is how I will read your summaries back to you.' \
    | "$(resolve_pick_py)" "$TARGET/kokoro-tts.py" "$pv_wav" "$1" 1.15 >/dev/null 2>&1
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

# --- modes used by the hook -------------------------------------------------
case "$1" in
  --preview)
    preview_voice "$2" >/dev/null 2>&1
    exit 0 ;;
  --session)
    sid="$2"; engine="${3:-kokoro}"
    if [ "$engine" != "kokoro" ]; then
      echo "The voice picker only covers Kokoro, the one engine whose voices can be auditioned offline."
      echo "You are on '$engine'. Switch with 'voice engine kokoro' first."
      sleep 6; exit 0
    fi
    [ -f "$ROOT/lib/kokoro-voices.json" ] || { echo "Voice catalogue not found."; sleep 5; exit 1; }
    KOKORO_VOICES=()
    while IFS= read -r line; do KOKORO_VOICES+=("$line"); done < <(
      node -e 'for (const v of require(process.argv[1])) console.log(`${v.id}|${v.lang}|${v.sex}|${v.grade}`)' \
        "$ROOT/lib/kokoro-voices.json"
    )
    flag="$STATE/voice.$engine.$sid"
    current="$(cfg_read kokoro_voice)"; [ -z "$current" ] && current="bf_emma"
    [ -f "$flag" ] && current="$(cat "$flag")"
    echo ""
    echo "agent-voice: pick a voice for this session"
    echo "-------------------------------------------"
    echo ""
    select_voice "$current"
    printf '%s' "$chosen_voice" > "$flag"
    echo ""
    echo "Voice set to $chosen_voice for this session."
    echo "You can close this window; your next reply will use it."
    sleep 3
    exit 0 ;;
esac
