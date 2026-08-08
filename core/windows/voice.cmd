@echo off
REM Toggle the agent-voice GLOBAL default on/off (per-session "voice on/off" overrides it).
if exist "%USERPROFILE%\.agent-voice\state\voice-on" (
  del "%USERPROFILE%\.agent-voice\state\voice-on"
  echo agent-voice global default: OFF
) else (
  if not exist "%USERPROFILE%\.agent-voice\state" mkdir "%USERPROFILE%\.agent-voice\state"
  type nul > "%USERPROFILE%\.agent-voice\state\voice-on"
  echo agent-voice global default: ON
)
