# agent-voice UserPromptSubmit hook (Windows).
#   1. Intercepts the in-session commands: voice on / voice text / voice off / voice status
#      (each toggles only the session it is typed in, keyed on session_id, and never
#       reaches Claude).
#   2. Otherwise, when voice is active for this session, injects the instruction that
#      asks Claude to end its reply with a plain-language <spoken> summary.

$ErrorActionPreference = 'SilentlyContinue'
$root  = Join-Path $env:USERPROFILE '.agent-voice'
$state = Join-Path $root 'state'
New-Item -ItemType Directory -Force -Path $state | Out-Null

$raw = [Console]::In.ReadToEnd()
try { $j = $raw | ConvertFrom-Json } catch { $j = $null }
$sid    = if ($j) { [string]$j.session_id } else { '' }
$prompt = if ($j) { [string]$j.prompt } else { '' }

$globalOn = Join-Path $state 'voice-on'
$onFlag   = if ($sid) { Join-Path $state "on.$sid" }
$offFlag  = if ($sid) { Join-Path $state "off.$sid" }
$textFlag = if ($sid) { Join-Path $state "text.$sid" }

# --- 1. in-session commands ---
$cmd = ($prompt.Trim().ToLower()) -replace '^[\\/]', ''
if ($sid -and $cmd -in @('voice on', 'voice text', 'voice off', 'voice status')) {
  switch ($cmd) {
    'voice on' {
      New-Item -ItemType File -Force -Path $onFlag | Out-Null
      Remove-Item $offFlag, $textFlag -Force -ErrorAction SilentlyContinue
      [Console]::Error.WriteLine('agent-voice: ON (summary + speech) for this session.')
    }
    'voice text' {
      New-Item -ItemType File -Force -Path $onFlag   | Out-Null
      New-Item -ItemType File -Force -Path $textFlag | Out-Null
      Remove-Item $offFlag -Force -ErrorAction SilentlyContinue
      [Console]::Error.WriteLine('agent-voice: TEXT-ONLY summary (no audio) for this session.')
    }
    'voice off' {
      Remove-Item $onFlag, $textFlag -Force -ErrorAction SilentlyContinue
      New-Item -ItemType File -Force -Path $offFlag | Out-Null
      [Console]::Error.WriteLine('agent-voice: OFF for this session.')
    }
    'voice status' {
      $st = if ($sid -and (Test-Path $textFlag)) { 'TEXT-ONLY (summary, no audio)' }
            elseif ($sid -and (Test-Path $onFlag)) { 'ON (summary + speech)' }
            elseif ((Test-Path $globalOn) -and -not (Test-Path $offFlag)) { 'ON (global default)' }
            else { 'OFF' }
      [Console]::Error.WriteLine("agent-voice: $st")
    }
  }
  exit 2   # block the command from reaching Claude
}

# --- 2. inject the summary instruction when active ---
$active = $false
if ($sid -and (Test-Path $onFlag)) { $active = $true }
elseif ((Test-Path $globalOn) -and -not ($sid -and (Test-Path $offFlag))) { $active = $true }
if (-not $active) { exit 0 }

@'
Voice mode is active. End every response with a <spoken> block on its own line.
Inside it: 2 to 3 sentences of plain prose. No markdown, no code, no file paths,
no lists, no symbols. State only what changed since my last message and what
decision I need to make. If nothing needs a decision, say what you did and stop.
Written to be heard, not read. Everything above the block stays normal.
'@

exit 0
