#!/usr/bin/env bash
# Toggle the agent-voice GLOBAL default on/off (per-session "voice on/off" overrides it).
STATE="$HOME/.agent-voice/state"
mkdir -p "$STATE"
if [ -f "$STATE/voice-on" ]; then
  rm -f "$STATE/voice-on"
  echo "agent-voice global default: OFF"
else
  : > "$STATE/voice-on"
  echo "agent-voice global default: ON"
fi
