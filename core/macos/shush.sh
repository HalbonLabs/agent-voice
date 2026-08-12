#!/usr/bin/env bash
# Stops any in-progress agent-voice speech immediately (all sessions).
# Thin wrapper: the identity-checked kill logic lives once, in src/stop.mjs.
# Resolves stop.mjs relative to itself first, so it works both from the repo
# (core/macos/shush.sh -> ../../src) and installed flat (~/.agent-voice/shush.sh -> ./src).
DIR="$(cd "$(dirname "$0")" && pwd)"
for cand in "$DIR/../../src/stop.mjs" "$DIR/src/stop.mjs" "$HOME/.agent-voice/src/stop.mjs"; do
  if [ -f "$cand" ]; then exec node "$cand"; fi
done
echo "agent-voice: stop.mjs not found; re-run the installer." >&2
exit 1
