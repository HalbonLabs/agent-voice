#!/usr/bin/env bash
# agent-voice installer (macOS/Linux). Interactive: choose agents and a voice engine.
# Run:  bash install.sh
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/.agent-voice"
STATE="$TARGET/state"

echo ""
echo "agent-voice installer"
echo "---------------------"

if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: node not found on PATH. Node ships with these agents; install it first."
  exit 1
fi

# Copy runtime files.
mkdir -p "$STATE" "$TARGET/lib"
cp -f "$SRC/core/macos/"* "$TARGET/"
cp -f "$SRC/lib/"* "$TARGET/lib/"
chmod +x "$TARGET"/*.sh
echo "Installed scripts to $TARGET"

# Choose agents.
echo ""
echo "Which agents should use agent-voice? (comma-separated)"
echo "  claude   Claude Code       fully supported (summary + voice)"
echo "  codex    Codex CLI         fully supported (summary + voice); please smoke-test"
echo "  kimi     Kimi Code CLI     summary text supported; voice pending upstream support"
echo ""
printf "Agents (Enter for claude): "
read -r agents
[ -z "$agents" ] && agents="claude"

# Choose engine.
echo ""
echo "Choose a voice engine:"
echo "  [1] edge-tts (Ava)   Free, natural. Short summary text sent to Microsoft. Needs Python 3. Quality: very good."
echo "  [2] ElevenLabs       Top quality. Uses your API key; summary text sent to ElevenLabs. Quality: best."
echo "  [3] Native offline   Fully private, nothing leaves the machine. Uses macOS 'say'."
echo ""
printf "Enter 1, 2, or 3: "
read -r choice

CFG="$TARGET/config"; : > "$CFG"
case "$choice" in
  2)
    echo "engine=elevenlabs" >> "$CFG"
    printf "Paste your ElevenLabs API key: "
    stty -echo; read -r key; stty echo; echo ""
    printf '%s' "$key" > "$TARGET/elevenlabs-key"; chmod 600 "$TARGET/elevenlabs-key"
    printf 'Voice ID (Enter for default British male "George"): '
    read -r vid; [ -z "$vid" ] && vid="JBFqnCBsd6RMkjVDRZzb"
    echo "eleven_voice=$vid" >> "$CFG"
    echo "eleven_model=eleven_flash_v2_5" >> "$CFG"
    echo "ElevenLabs selected. Key stored locally (not in any script)."
    ;;
  3)
    echo "engine=native" >> "$CFG"
    echo "Native offline selected (macOS 'say'). Add premium voices in System Settings > Accessibility > Spoken Content."
    ;;
  *)
    echo "engine=edge" >> "$CFG"
    echo "edge_voice=en-US-AvaNeural" >> "$CFG"
    echo "edge_rate=+15%" >> "$CFG"
    echo "edge-tts (Ava) selected."
    if ! python3 -m edge_tts --version >/dev/null 2>&1; then
      echo "Installing edge-tts (pip3 install --user edge-tts) ..."
      python3 -m pip install --user edge-tts
    fi
    ;;
esac

# Global default ON so it works immediately.
: > "$STATE/voice-on"

# Register hooks into the chosen agents.
echo ""
node "$TARGET/lib/register.mjs" mode=install home="$HOME" platform=mac scripts="$TARGET" providers="$agents"

echo ""
echo "Done."
echo "Reload any open agent session so it picks up the hooks."
echo "In any session, type:  voice on  |  voice text  |  voice off  |  voice status"
echo "Stop speech anytime:   run  $TARGET/shush.sh  (bind it to a hotkey via the Shortcuts app)"
