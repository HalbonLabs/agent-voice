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
cfg_engine="edge"
cfg_python="python3"
if [ -f "$ROOT/config" ]; then
  cfg_engine="$(sed -n 's/^[[:space:]]*engine[[:space:]]*=[[:space:]]*//p' "$ROOT/config" | tail -1)"
  # python_cmd is the current spelling; kokoro_python is accepted as an older one.
  found_py="$(sed -n 's/^[[:space:]]*\(python_cmd\|kokoro_python\)[[:space:]]*=[[:space:]]*//p' "$ROOT/config" | tail -1)"
  [ -n "$found_py" ] && cfg_python="$found_py"
fi
[ -z "$cfg_engine" ] && cfg_engine="edge"

RAW="$(cat)"
sid="$(printf '%s' "$RAW" | node "$ROOT/lib/json-get.mjs" session_id)"
prompt="$(printf '%s' "$RAW" | node "$ROOT/lib/json-get.mjs" prompt)"

global_on="$STATE/voice-on"
on_flag="$STATE/on.$sid"
off_flag="$STATE/off.$sid"
text_flag="$STATE/text.$sid"
eng_flag="$STATE/engine.$sid"

# Normalise the command: lowercase, strip a leading slash or backslash.
cmd="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's#^[\\/]##')"

if [ -n "$sid" ]; then
  case "$cmd" in
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
      if [ -f "$eng_flag" ]; then eng="$(cat "$eng_flag") (this session)"
      else eng="$cfg_engine (default)"; fi
      echo "agent-voice: $st, engine $eng" >&2; exit 2 ;;
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
