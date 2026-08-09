#!/usr/bin/env bash
# agent-voice Stop hook (macOS). Speaks the <spoken> block for the active session,
# using the engine chosen at install time. Falls back to the offline `say`
# command. The heavy work is backgrounded so the hook returns immediately.

ROOT="$HOME/.agent-voice"
STATE="$ROOT/state"
mkdir -p "$STATE"

# Load config (simple key=value file; safe to source, values have no spaces).
[ -f "$ROOT/config" ] && . "$ROOT/config"
engine="${engine:-edge}"

# Which interpreter to use. Bare python3 resolves against the PATH of whichever
# agent launched the hook, which is not necessarily the one the dependencies were
# installed into: a project venv earlier on PATH produces a missing-dependency
# exit and a silent drop to the robotic voice. The installer records the
# interpreter it verified. kokoro_python is accepted as an older spelling.
py_cmd="${python_cmd:-${kokoro_python:-python3}}"

RAW="$(cat)"
[ -z "$RAW" ] && exit 0
sid="$(printf '%s' "$RAW" | node "$ROOT/lib/json-get.mjs" session_id)"

global_on="$STATE/voice-on"
on_flag="$STATE/on.$sid"
off_flag="$STATE/off.$sid"
text_flag="$STATE/text.$sid"

# Active for this session?
active=0
if [ -n "$sid" ] && [ -f "$on_flag" ]; then active=1
elif [ -f "$global_on" ] && ! { [ -n "$sid" ] && [ -f "$off_flag" ]; }; then active=1
fi
[ "$active" = 1 ] || exit 0

# Text-only mode: no audio.
[ -n "$sid" ] && [ -f "$text_flag" ] && exit 0

# A per-session engine override ("voice engine kokoro") beats the installed default,
# so different windows can speak with different engines at the same time.
if [ -n "$sid" ] && [ -f "$STATE/engine.$sid" ]; then
  override="$(cat "$STATE/engine.$sid")"
  [ -n "$override" ] && engine="$override"
fi

# Speed is one number across every engine, 1.0 being normal. Each engine below
# converts it to whatever it actually wants, so the user only ever sees one scale.
speed_mul=""
[ -n "$sid" ] && [ -f "$STATE/speed.$sid" ] && speed_mul="$(cat "$STATE/speed.$sid")"
[ -z "$speed_mul" ] && speed_mul="${voice_speed:-}"

msg="$(printf '%s' "$RAW" | node "$ROOT/lib/json-get.mjs" last_assistant_message)"

# Kimi Code's Stop payload has no last_assistant_message at all, so recover the
# reply from its session transcript. Only runs when the field is genuinely absent,
# which leaves Claude Code and Codex untouched.
if [ -z "$msg" ] && [ -f "$ROOT/lib/kimi-last-text.mjs" ]; then
  case "$sid" in
    session_*) msg="$(node "$ROOT/lib/kimi-last-text.mjs" "$sid" "$HOME")" ;;
  esac
fi

[ -z "$msg" ] && exit 0
spoken="$(printf '%s' "$msg" | node "$ROOT/lib/extract-spoken.mjs")"
[ -z "$spoken" ] && exit 0

tag="${sid:-nosession}"
pidfile="$STATE/speak.$tag.pid"
mp3="$STATE/say.$tag.mp3"
wav="$STATE/say.$tag.wav"

# Cut off this session's previous turn if still speaking.
[ -f "$pidfile" ] && kill "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null

# Do synthesis + playback in the background so the hook returns at once.
(
  echo $$ > "$pidfile"
  spoke=0
  rm -f "$mp3" "$wav"

  if [ "$engine" = "edge" ]; then
    voice="${edge_voice:-en-US-AvaNeural}"
    rate="${edge_rate:-+15%}"
    # edge-tts wants a percentage delta, so 1.25x becomes +25%.
    [ -n "$speed_mul" ] && rate="$(awk -v m="$speed_mul" 'BEGIN{p=sprintf("%.0f",(m-1)*100)+0; printf (p>=0 ? "+%d%%" : "%d%%"), p}')"
    "$py_cmd" -m edge_tts --text "$spoken" --voice "$voice" --rate="$rate" --write-media "$mp3" 2>/dev/null
    # Only count it as spoken if afplay itself succeeded, so a playback failure
    # falls through to `say` instead of leaving the reply silent.
    if [ -s "$mp3" ] && afplay "$mp3"; then spoke=1; fi
  elif [ "$engine" = "kokoro" ]; then
    # Offline neural voice. ~1.7s once the warm daemon is up; the client starts one
    # if it is not. The very first call ever also downloads weights, and that turn
    # takes ~12s or falls back to `say`.
    voice="${kokoro_voice:-bf_emma}"
    speed="${speed_mul:-${kokoro_speed:-1.15}}"
    if [ -f "$ROOT/kokoro-tts.py" ]; then
      printf '%s' "$spoken" | "$py_cmd" "$ROOT/kokoro-tts.py" "$wav" "$voice" "$speed" 2>/dev/null
      if [ -s "$wav" ] && [ "$(wc -c < "$wav")" -gt 500 ] && afplay "$wav"; then spoke=1; fi
    fi
  elif [ "$engine" = "elevenlabs" ]; then
    key=""; [ -f "$ROOT/elevenlabs-key" ] && key="$(cat "$ROOT/elevenlabs-key")"
    voice="${eleven_voice:-JBFqnCBsd6RMkjVDRZzb}"
    model="${eleven_model:-eleven_flash_v2_5}"
    if [ -n "$key" ]; then
      body="$(node "$ROOT/lib/eleven-body.mjs" "$spoken" "$model")"
      curl -s -X POST "https://api.elevenlabs.io/v1/text-to-speech/$voice?output_format=mp3_44100_128" \
        -H "xi-api-key: $key" -H "Content-Type: application/json" -d "$body" -o "$mp3"
      if [ -s "$mp3" ] && [ "$(wc -c < "$mp3")" -gt 500 ] && afplay "$mp3"; then spoke=1; fi
    fi
  fi

  # Fallback: offline macOS `say`.
  if [ "$spoke" = 0 ]; then
    # say takes words per minute; its default is about 175.
    say_args=""
    [ -n "$speed_mul" ] && say_args="-r $(awk -v m="$speed_mul" 'BEGIN{printf "%d", 175*m}')"
    if [ -n "${native_voice:-}" ]; then say $say_args -v "$native_voice" "$spoken"; else say $say_args "$spoken"; fi
  fi

  rm -f "$mp3" "$wav" "$pidfile"
) >/dev/null 2>&1 &
disown 2>/dev/null

exit 0
