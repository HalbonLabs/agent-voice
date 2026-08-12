# Stops any in-progress agent-voice speech immediately (all sessions).
# Thin wrapper: the identity-checked kill logic lives once, in src/stop.mjs.
# Resolves stop.mjs relative to itself first, so it works both from the repo
# (core/windows/shush.ps1 -> ..\..\src) and installed flat (~/.agent-voice/shush.ps1 -> .\src).
$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cands = @(
  (Join-Path $here '..\..\src\stop.mjs'),
  (Join-Path $here 'src\stop.mjs'),
  (Join-Path $env:USERPROFILE '.agent-voice\src\stop.mjs')
)
foreach ($c in $cands) {
  if (Test-Path $c) { node $c; exit $LASTEXITCODE }
}
Write-Host 'agent-voice: stop.mjs not found; re-run the installer.'
exit 1
