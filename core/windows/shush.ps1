# Stops any in-progress agent-voice speech immediately (all sessions).
$ErrorActionPreference = 'SilentlyContinue'
$state = Join-Path $env:USERPROFILE '.agent-voice\state'

# Kill every tracked speak process (one speak.<sid>.pid per session).
Get-ChildItem (Join-Path $state 'speak.*.pid') -ErrorAction SilentlyContinue | ForEach-Object {
  $p = Get-Content $_.FullName
  if ($p) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
  Remove-Item $_.FullName -ErrorAction SilentlyContinue
}

# Killing the speak process skips its own cleanup, so tidy up the temp audio here
# rather than leaving a file per interrupted session behind.
Get-ChildItem $state -Filter 'say.*' -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -in @('.wav', '.mp3') } |
  ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

Write-Host 'agent-voice: speech stopped.'
