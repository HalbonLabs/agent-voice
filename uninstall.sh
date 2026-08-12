#!/usr/bin/env bash
# agent-voice uninstaller (macOS; also works on Linux for pre-R-10 installs).
# Removes hooks from all agents and (optionally) the files.
TARGET="$HOME/.agent-voice"

# Stop the Kokoro daemon first, if one is resident, so its memory is freed now.
# Use the SAME interpreter the installer recorded: the dependencies live in
# ~/.agent-voice/venv, so a bare python3 here cannot import kokoro and the quit
# silently no-ops, leaving the daemon resident with ~1.7GB held after uninstall.
cfg_read() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$TARGET/config" 2>/dev/null | tail -1; }
quit_py="$(cfg_read python_cmd)"; [ -z "$quit_py" ] && quit_py="$(cfg_read kokoro_python)"
[ -z "$quit_py" ] || [ ! -x "$quit_py" ] && quit_py="python3"
if [ -f "$TARGET/kokoro_serve.py" ]; then
  "$quit_py" "$TARGET/kokoro_serve.py" "$TARGET/state" --quit >/dev/null 2>&1 || true
fi

if [ -f "$TARGET/lib/register.mjs" ]; then
  node "$TARGET/lib/register.mjs" mode=uninstall home="$HOME"
else
  echo "register.mjs not found; edit your agent config(s) by hand to remove agent-voice hooks."
fi

printf "Also delete installed files and settings at ~/.agent-voice? (y/N): "
read -r ans
if [ "$ans" = "y" ]; then
  rm -rf "$TARGET"; echo "Removed ~/.agent-voice (including the private venv)"
  # The installer creates this; uninstall used to leave it behind, pointing at
  # scripts that no longer exist, so the Quick Action stayed in System Settings
  # and did nothing when triggered.
  qa="$HOME/Library/Services/Stop agent-voice.workflow"
  if [ -d "$qa" ]; then
    rm -rf "$qa"
    /System/Library/CoreServices/pbs -flush >/dev/null 2>&1 || true
    echo "Removed the Stop agent-voice Quick Action"
  fi
else
  echo "Left ~/.agent-voice in place (hooks removed)."
fi
echo "Reload open agent sessions to drop the hooks."
