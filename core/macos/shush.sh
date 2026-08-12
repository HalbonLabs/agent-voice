#!/usr/bin/env bash
# Stops any in-progress agent-voice speech immediately (all sessions).
STATE="$HOME/.agent-voice/state"

for f in "$STATE"/speak.*.pid; do
  [ -f "$f" ] || continue
  old="$(cat "$f" 2>/dev/null)"
  # Verify the PID is still one of our speak subshells before signalling; after
  # PID reuse it could be anything. Children first, so the player stops too.
  case "$old" in
    ''|*[!0-9]*) ;;
    *) if ps -p "$old" -o command= 2>/dev/null | grep -q 'speak\.sh'; then
         pkill -P "$old" 2>/dev/null
         kill "$old" 2>/dev/null
       fi ;;
  esac
  rm -f "$f"
done

# Backstop for players orphaned by a kill above: match only processes playing
# OUR audio files, never every afplay and say the user has running (R-15).
pkill -f "$STATE/say\." 2>/dev/null

# Killing the speak process skips its own cleanup, so tidy up the temp audio here
# rather than leaving a file per interrupted session behind.
rm -f "$STATE"/say.*.wav "$STATE"/say.*.mp3

echo "agent-voice: speech stopped."
