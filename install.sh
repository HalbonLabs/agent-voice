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
cp -f "$SRC/core/"kokoro*.py "$TARGET/"
cp -f "$SRC/lib/"* "$TARGET/lib/"
chmod +x "$TARGET"/*.sh
echo "Installed scripts to $TARGET"

# Choose agents.
echo ""
echo "Which agents should use agent-voice? (comma-separated)"
echo "  claude   Claude Code       fully supported (summary + voice)"
echo "  codex    Codex CLI         supported (summary + voice); checked against the docs, not yet run live"
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
echo "  [3] Kokoro offline   Free, natural, fully private. Needs Python 3 + ~300MB weights. Quality: good."
echo "  [4] Native offline   Fully private, no downloads, nothing to install. Uses macOS 'say'. Quality: robotic."
echo ""
printf "Enter 1, 2, 3, or 4: "
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
    printf 'Kokoro voice (Enter for British female "bf_emma"): '
    read -r kv; [ -z "$kv" ] && kv="bf_emma"
    echo "engine=kokoro" >> "$CFG"
    echo "kokoro_voice=$kv" >> "$CFG"
    echo "kokoro_speed=1.15" >> "$CFG"
    echo "Kokoro offline selected. Nothing will leave this machine."

    echo "Kokoro keeps a warm background process so replies start speaking in ~1.7s."
    echo "It uses about 1.7GB of RAM while resident, and exits after 15 idle minutes."

    # espeak-ng is not required: the espeakng-loader dependency bundles it.
    if ! python3 -c 'import kokoro, soundfile' >/dev/null 2>&1; then
      echo "Installing Kokoro (pip3 install --user kokoro soundfile) ... this pulls in PyTorch and takes a few minutes."
      python3 -m pip install --user kokoro soundfile
    fi

    # Warm up: pre-download the weights and the spaCy model that Kokoro's text
    # front-end fetches on first use, so the first spoken reply is not silent.
    echo "Downloading Kokoro voice weights (~300MB) and language model (one time) ..."
    probe="$STATE/warmup.wav"
    printf 'agent voice is ready' | python3 "$TARGET/kokoro-tts.py" "$probe" "$kv" 1.15 || true
    if [ -s "$probe" ] && [ "$(wc -c < "$probe")" -gt 500 ]; then
      echo "Kokoro is working."
      rm -f "$probe"
    else
      echo "Kokoro could not synthesise yet. Voice will use the basic 'say' voice until this is fixed;"
      echo "run the pip3 install above by hand to see the error."
    fi
    ;;
  4)
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
echo "Try another engine in one session only:  voice engine edge  (or kokoro/elevenlabs/native)"
echo "Stop speech anytime:   run  $TARGET/shush.sh  (bind it to a hotkey via the Shortcuts app)"
