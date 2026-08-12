# Stops any in-progress agent-voice speech immediately (all sessions).
$ErrorActionPreference = 'SilentlyContinue'
$state = Join-Path $env:USERPROFILE '.agent-voice\state'

# Kill every tracked speak process (one speak.<sid>.pid per session), but only
# after checking the PID is still one of ours: after PID reuse it could belong
# to an unrelated process.
Get-ChildItem (Join-Path $state 'speak.*.pid') -ErrorAction SilentlyContinue | ForEach-Object {
  $p = (Get-Content $_.FullName -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($p -match '^\d+$') {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue).CommandLine
    if ($cmd -and $cmd -match 'speak\.ps1') {
      Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
    }
  }
  Remove-Item $_.FullName -ErrorAction SilentlyContinue
}

# Killing the speak process skips its own cleanup, so tidy up the temp audio and
# any unread job files here rather than leaving a file per interrupted session.
Get-ChildItem (Join-Path $state 'job.*.json') -ErrorAction SilentlyContinue |
  ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
Get-ChildItem $state -Filter 'say.*' -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in @('.wav', '.mp3') } |
  ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

Write-Host 'agent-voice: speech stopped.'
