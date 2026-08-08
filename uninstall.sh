#!/usr/bin/env bash
# agent-voice uninstaller (macOS/Linux). Removes hooks from all agents and (optionally) the files.
TARGET="$HOME/.agent-voice"

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
