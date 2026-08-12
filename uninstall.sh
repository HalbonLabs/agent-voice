#!/usr/bin/env bash
# agent-voice uninstaller (macOS; also works on Linux for pre-R-10 installs).
# Removes hooks from all agents and (optionally) the files.
TARGET="$HOME/.agent-voice"

# Stop the Kokoro daemon first, if one is resident, so its memory is freed now.
if [ -f "$TARGET/kokoro_serve.py" ]; then
  python3 "$TARGET/kokoro_serve.py" "$TARGET/state" --quit >/dev/null 2>&1 || true
fi

if [ -f "$TARGET/lib/register.mjs" ]; then
  node "$TARGET/lib/register.mjs" mode=uninstall home="$HOME"
else
  echo "register.mjs not found; edit your agent config(s) by hand to remove agent-voice hooks."
fi

printf "Also delete installed files and settings at ~/.agent-voice? (y/N): "
read -r ans
if [ "$ans" = "y" ]; then rm -rf "$TARGET"; echo "Removed ~/.agent-voice"
else echo "Left ~/.agent-voice in place (hooks removed)."; fi
echo "Reload open agent sessions to drop the hooks."
