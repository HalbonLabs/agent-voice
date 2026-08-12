#!/usr/bin/env bash
# Toggle the agent-voice GLOBAL default on/off (per-session "voice on/off" overrides it).
STATE="$HOME/.agent-voice/state"
mkdir -p "$STATE"
chmod 700 "$STATE" 2>/dev/null  # owner-only: kokoro.port in here carries the daemon token
if [ -f "$STATE/voice-on" ]; then
  rm -f "$STATE/voice-on"
  echo "agent-voice global default: OFF"
else
  : > "$STATE/voice-on"
  echo "agent-voice global default: ON"
fi
