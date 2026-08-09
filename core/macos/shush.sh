#!/usr/bin/env bash
# Stops any in-progress agent-voice speech immediately (all sessions).
STATE="$HOME/.agent-voice/state"

for f in "$STATE"/speak.*.pid; do
  [ -f "$f" ] || continue
  kill "$(cat "$f" 2>/dev/null)" 2>/dev/null
  rm -f "$f"
done

# Belt and braces: stop the players agent-voice uses.
killall afplay say 2>/dev/null

# Killing the speak process skips its own cleanup, so tidy up the temp audio here
# rather than leaving a file per interrupted session behind.
rm -f "$STATE"/say.*.wav "$STATE"/say.*.mp3

echo "agent-voice: speech stopped."
