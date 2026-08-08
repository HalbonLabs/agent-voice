#!/usr/bin/env bash
# agent-voice UserPromptSubmit hook (macOS).
#   1. Intercepts in-session commands: voice on / voice text / voice off / voice status.
#   2. Otherwise injects the <spoken> summary instruction when voice is active.

ROOT="$HOME/.agent-voice"
STATE="$ROOT/state"
mkdir -p "$STATE"

RAW="$(cat)"
sid="$(printf '%s' "$RAW" | node "$ROOT/lib/json-get.mjs" session_id)"
prompt="$(printf '%s' "$RAW" | node "$ROOT/lib/json-get.mjs" prompt)"

global_on="$STATE/voice-on"
on_flag="$STATE/on.$sid"
off_flag="$STATE/off.$sid"
text_flag="$STATE/text.$sid"

# Normalise the command: lowercase, strip a leading slash or backslash.
cmd="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's#^[\\/]##')"

if [ -n "$sid" ]; then
  case "$cmd" in
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
      echo "agent-voice: $st" >&2; exit 2 ;;
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
