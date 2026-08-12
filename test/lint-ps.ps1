# Parse-gates every PowerShell file in the repo, then runs PSScriptAnalyzer if
# it is installed. A parse error anywhere fails the script, which is the cheap
# half of what CI needs: a .ps1 that will not even parse can never work.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -Path $root -Recurse -Filter *.ps1 |
  Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.FullName -notmatch '[\\/]node_modules[\\/]' }

$failed = $false
foreach ($f in $files) {
  $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count -gt 0) {
    $failed = $true
    Write-Host "PARSE FAIL $($f.FullName)"
    foreach ($e in $errs) { Write-Host "  $($e.Extent.StartLineNumber): $($e.Message)" }
  } else {
    Write-Host "ok $($f.FullName)"
  }
}

if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
  $findings = $files | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Severity Error }
  if ($findings) {
    $failed = $true
    $findings | ForEach-Object { Write-Host "ANALYZER $($_.ScriptName):$($_.Line) $($_.RuleName): $($_.Message)" }
  }
} else {
  Write-Host 'PSScriptAnalyzer not installed; parse gate only.'
}

if ($failed) { exit 1 }
exit 0
