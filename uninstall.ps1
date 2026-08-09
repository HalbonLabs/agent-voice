# agent-voice uninstaller (Windows). Removes the hooks from all agents and (optionally) the files.
$ErrorActionPreference = 'SilentlyContinue'
$target = Join-Path $env:USERPROFILE '.agent-voice'

# Stop the Kokoro daemon first, if one is resident, so its memory is freed now.
$serve = Join-Path $target 'kokoro_serve.py'
if (Test-Path $serve) { python $serve (Join-Path $target 'state') --quit 2>$null }

$reg = Join-Path $target 'lib\register.mjs'
if (Test-Path $reg) {
  node $reg mode=uninstall home=$env:USERPROFILE
} else {
  Write-Host 'register.mjs not found; edit your agent config(s) by hand to remove agent-voice hooks.' -ForegroundColor Yellow
}

Remove-Item (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\agent-voice stop.lnk') -Force -ErrorAction SilentlyContinue

$ans = Read-Host 'Also delete installed files and settings at ~/.agent-voice? (y/N)'
if ($ans -eq 'y') { Remove-Item $target -Recurse -Force; Write-Host 'Removed ~/.agent-voice' }
else { Write-Host 'Left ~/.agent-voice in place (hooks removed).' }
Write-Host 'Reload open agent sessions to drop the hooks.'
