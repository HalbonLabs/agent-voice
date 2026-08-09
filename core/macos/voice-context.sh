#!/usr/bin/env bash
# agent-voice UserPromptSubmit hook (macOS).
#   1. Intercepts in-session commands: voice on / voice text / voice off /
#      voice status / voice engine <name>.
#   2. Otherwise injects the <spoken> summary instruction when voice is active.

ROOT="$HOME/.agent-voice"
STATE="$ROOT/state"
mkdir -p "$STATE"

ENGINES="edge kokoro elevenlabs native"

# Installed default engine, used when a session has no override of its own.
cfg_get() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ROOT/config" 2>/dev/null | tail -1; }

cfg_engine="edge"
cfg_python="python3"
if [ -f "$ROOT/config" ]; then
  found="$(cfg_get engine)";      [ -n "$found" ] && cfg_engine="$found"
  # python_cmd is the current spelling; kokoro_python is accepted as an older one.
  found="$(cfg_get python_cmd)";  [ -z "$found" ] && found="$(cfg_get kokoro_python)"
  [ -n "$found" ] && cfg_python="$found"
fi

# Speed is one number across every engine, 1.0 being normal, because each engine
# expresses it differently (Kokoro a multiplier, edge-tts a percentage, say a words
# per minute figure). The engines convert it; the user sees one scale.
default_speed() {
  s="$(cfg_get voice_speed)"
  if [ -n "$s" ]; then printf '%s' "$s"; return; fi
  case "$1" in
    kokoro) s="$(cfg_get kokoro_speed)"; printf '%s' "${s:-1.15}" ;;
    edge)
      r="$(cfg_get edge_rate)"
      case "$r" in
        [+-]*%) printf '%s' "$(awk -v p="${r%\%}" 'BEGIN{printf "%.2f", 1 + p/100}')" ;;
        *) printf '1.15' ;;
      esac ;;
    native) printf '1.2' ;;
    *) printf '1.0' ;;
  esac
}

voice_name() {
  case "$1" in
    kokoro)     s="$(cfg_get kokoro_voice)"; printf '%s' "${s:-bf_emma}" ;;
    edge)       s="$(cfg_get edge_voice)";   printf '%s' "${s:-en-US-AvaNeural}" ;;
    elevenlabs) s="$(cfg_get eleven_voice)"; printf '%s' "${s:-JBFqnCBsd6RMkjVDRZzb}" ;;
    *)          s="$(cfg_get native_voice)"; printf '%s' "${s:-system default}" ;;
  esac
}

RAW="$(cat)"
sid="$(printf '%s' "$RAW" | node "$ROOT/lib/json-get.mjs" session_id)"
prompt="$(printf '%s' "$RAW" | node "$ROOT/lib/json-get.mjs" prompt)"

global_on="$STATE/voice-on"
on_flag="$STATE/on.$sid"
off_flag="$STATE/off.$sid"
text_flag="$STATE/text.$sid"
eng_flag="$STATE/engine.$sid"
spd_flag="$STATE/speed.$sid"

# Normalise the command: lowercase, strip a leading slash or backslash.
cmd="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's#^[\\/]##')"

# The engine in effect for this session, which the voice commands below act on.
cur_engine="$cfg_engine"
[ -f "$eng_flag" ] && cur_engine="$(cat "$eng_flag")"
vce_flag="$STATE/voice.$cur_engine.$sid"

if [ -n "$sid" ]; then
  case "$cmd" in
    "voice help")
      {
        echo "agent-voice commands (each affects this session only):"
        echo "  voice on                summary plus spoken audio"
        echo "  voice text              summary only, no audio"
        echo "  voice off               back to normal replies"
        echo "  voice status            what this session will use right now"
        echo "  voice engine <name>     edge | kokoro | elevenlabs | native"
        echo "  voice model <id>        change the voice itself, e.g. voice model af_heart"
        echo "  voice speed <n>         0.5 to 2.0, where 1.0 is normal"
        echo "  voice list              voices available for the current engine"
        echo "  voice help              this list"
        echo ""
        echo "  Add 'default' to reset one, for example: voice speed default"
        echo "  Stop speech immediately: run ~/.agent-voice/shush.sh"
      } >&2
      exit 2 ;;

    "voice list"|"voice list "*)
      arg="${cmd#voice list}"
      arg="$(printf '%s' "$arg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      case "$cur_engine" in
        kokoro)
          if [ -f "$ROOT/lib/kokoro-voices.json" ]; then
            filter="British American"
            [ "$arg" = "all" ] && filter=""
            node -e '
              const v = require(process.argv[1]);
              const f = process.argv[2] ? process.argv[2].split(" ") : null;
              const rows = f ? v.filter(x => f.includes(x.lang)) : v;
              console.error(`agent-voice: Kokoro voices (${rows.length} shown). Grades are the model own.`);
              for (const r of rows) console.error(`  ${r.id.padEnd(14)} ${r.lang.padEnd(11)} ${r.sex.padEnd(7)} grade ${r.grade}`);
            ' "$ROOT/lib/kokoro-voices.json" "$filter"
            [ -n "$filter" ] && echo "  'voice list all' also shows the other 7 languages." >&2
            echo "  Switch with: voice model <id>" >&2
          fi ;;
        edge)
          {
            echo "agent-voice: common edge-tts voices:"
            echo "  en-GB-SoniaNeural   British female"
            echo "  en-GB-RyanNeural    British male"
            echo "  en-US-AvaNeural     American female"
            echo "  en-US-AndrewNeural  American male"
            echo "  Full list: python3 -m edge_tts --list-voices"
            echo "  Switch with: voice model <id>"
          } >&2 ;;
        elevenlabs)
          {
            echo "agent-voice: ElevenLabs voice ids come from your own account at elevenlabs.io/voice-library."
            echo "  Switch with: voice model <voice-id>"
          } >&2 ;;
        *)
          {
            echo "agent-voice: the native engine uses the voice built into the OS."
            echo "  macOS: System Settings > Accessibility > Spoken Content > System Voice."
          } >&2 ;;
      esac
      exit 2 ;;

    "voice model"|"voice model "*|"voice voice"|"voice voice "*)
      # Change the voice itself for this session. Stored per engine, so switching
      # engine does not carry a Kokoro id over to edge-tts where it means nothing.
      arg="${cmd#voice }"; arg="${arg#model}"; arg="${arg#voice}"
      arg="$(printf '%s' "$arg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      if [ -z "$arg" ] || [ "$arg" = "default" ]; then
        rm -f "$vce_flag"
        echo "agent-voice: voice override cleared; $cur_engine is back to $(voice_name "$cur_engine")" >&2
      else
        ok=1
        if [ "$cur_engine" = "kokoro" ] && [ -f "$ROOT/lib/kokoro-voices.json" ]; then
          node -e 'process.exit(require(process.argv[1]).some(v => v.id === process.argv[2]) ? 0 : 1)' \
            "$ROOT/lib/kokoro-voices.json" "$arg" || ok=0
        fi
        if [ "$ok" = 1 ]; then
          printf '%s' "$arg" > "$vce_flag"
          echo "agent-voice: voice for this session is now $arg (engine $cur_engine)" >&2
        else
          echo "agent-voice: '$arg' is not a Kokoro voice. Try 'voice list' to see them." >&2
        fi
      fi
      exit 2 ;;

    "voice speed"|"voice speed "*)
      # How fast the summary is read, in this session only. One scale across all
      # engines, 1.0 normal, since spoken summaries are often the thing you want
      # to get through quickly.
      arg="${cmd#voice speed}"
      arg="$(printf '%s' "$arg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      if [ -z "$arg" ] || [ "$arg" = "default" ]; then
        rm -f "$spd_flag"
        eng="$cfg_engine"; [ -f "$eng_flag" ] && eng="$(cat "$eng_flag")"
        echo "agent-voice: speed override cleared; back to $(default_speed "$eng")x" >&2
      elif printf '%s' "$arg" | grep -Eq '^[0-9]+(\.[0-9]+)?$' \
        && awk -v v="$arg" 'BEGIN{exit !(v >= 0.5 && v <= 2.0)}'; then
        printf '%s' "$arg" > "$spd_flag"
        echo "agent-voice: speed for this session is now ${arg}x (1.0 is normal)" >&2
      else
        echo "agent-voice: speed must be a number between 0.5 and 2.0, for example 'voice speed 1.5'. Use 'voice speed default' to reset." >&2
      fi
      exit 2 ;;
    "voice engine"|"voice engine "*)
      arg="${cmd#voice engine}"
      arg="$(printf '%s' "$arg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      if [ -z "$arg" ] || [ "$arg" = "default" ]; then
        rm -f "$eng_flag"
        echo "agent-voice: engine override cleared; this session uses the default ($cfg_engine)." >&2
      elif printf '%s' " $ENGINES " | grep -q " $arg "; then
        printf '%s' "$arg" > "$eng_flag"
        note=""
        if [ "$arg" = "elevenlabs" ] && [ ! -f "$ROOT/elevenlabs-key" ]; then
          note=" (no API key stored, so it will fall back to the native voice)"
        fi
        if [ "$arg" = "kokoro" ] && [ -f "$ROOT/kokoro_serve.py" ]; then
          # Warm the model now so the first reply on the new engine is not slow.
          ("$cfg_python" "$ROOT/kokoro_serve.py" "$STATE" >/dev/null 2>&1 &)
          note=" (warming the model now)"
        fi
        echo "agent-voice: engine for this session is now $arg$note" >&2
      else
        echo "agent-voice: unknown engine '$arg'. Choose from: $ENGINES, or 'default'." >&2
      fi
      exit 2 ;;
    "voice on")
      : > "$on_flag"; rm -f "$off_flag" "$text_flag"
      echo "agent-voice: ON (summary + speech) for this session." >&2; exit 2 ;;
    "voice text")
      : > "$on_flag"; : > "$text_flag"; rm -f "$off_flag"
      echo "agent-voice: TEXT-ONLY summary (no audio) for this session." >&2; exit 2 ;;
    "voice off")
      rm -f "$on_flag" "$text_flag"; : > "$off_flag"
      echo "agent-voice: OFF for this session." >&2; exit 2 ;;
    "voice status")
      if [ -f "$text_flag" ]; then st="TEXT-ONLY (summary, no audio)"
      elif [ -f "$on_flag" ]; then st="ON (summary + speech)"
      elif [ -f "$global_on" ] && [ ! -f "$off_flag" ]; then st="ON (global default)"
      else st="OFF"; fi
      if [ -f "$eng_flag" ]; then eng_name="$(cat "$eng_flag")"; eng_from="this session"
      else eng_name="$cfg_engine"; eng_from="default"; fi
      if [ -f "$spd_flag" ]; then spd_val="$(cat "$spd_flag")"; spd_from="this session"
      else spd_val="$(default_speed "$eng_name")"; spd_from="default"; fi
      {
        echo "agent-voice: $st"
        echo "  engine  $eng_name ($eng_from)"
        if [ -f "$STATE/voice.$eng_name.$sid" ]; then
          echo "  voice   $(cat "$STATE/voice.$eng_name.$sid") (this session)"
        else
          echo "  voice   $(voice_name "$eng_name") (default)"
        fi
        echo "  speed   ${spd_val}x ($spd_from, 1.0 is normal)"
        [ "$eng_name" = "elevenlabs" ] && echo "  note    ElevenLabs ignores speed; it has no rate control in this integration."
      } >&2
      exit 2 ;;
  esac
fi

# Inject the instruction when active.
active=0
if [ -n "$sid" ] && [ -f "$on_flag" ]; then active=1
elif [ -f "$global_on" ] && ! { [ -n "$sid" ] && [ -f "$off_flag" ]; }; then active=1
fi
[ "$active" = 1 ] || exit 0

cat <<'EOF'
Voice mode is active. End every response with a <spoken> block on its own line.
Inside it: 2 to 3 sentences of plain prose. No markdown, no code, no file paths,
no lists, no symbols. State only what changed since my last message and what
decision I need to make. If nothing needs a decision, say what you did and stop.
Written to be heard, not read. Everything above the block stays normal.
EOF
exit 0
