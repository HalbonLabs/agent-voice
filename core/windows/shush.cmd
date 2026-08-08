@echo off
REM Stop agent-voice speech immediately.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.agent-voice\shush.ps1"
