# agent-voice UserPromptSubmit hook (Windows).
#   1. Intercepts the in-session commands: voice on / voice text / voice off /
#      voice status / voice engine <name> (each affects only the session it is
#      typed in, keyed on session_id, and never reaches Claude).
#   2. Otherwise, when voice is active for this session, injects the instruction that
#      asks Claude to end its reply with a plain-language <spoken> summary.

$ErrorActionPreference = 'SilentlyContinue'
$root  = Join-Path $env:USERPROFILE '.agent-voice'
$state = Join-Path $root 'state'
New-Item -ItemType Directory -Force -Path $state | Out-Null

$ENGINES = @('edge', 'kokoro', 'elevenlabs', 'native')
$SPEED_MIN = 0.5
$SPEED_MAX = 2.0

# Installed defaults, used when a session has no override of its own.
$cfg = @{}
$cfgFile = Join-Path $root 'config'
if (Test-Path $cfgFile) {
  Get-Content $cfgFile | ForEach-Object {
    if ($_ -match '^\s*([^#=]+?)\s*=\s*(.*)$') { $cfg[$matches[1].Trim()] = $matches[2].Trim() }
  }
}
$cfgEngine = if ($cfg.engine) { $cfg.engine } else { 'edge' }
$cfgPython = if ($cfg.python_cmd) { $cfg.python_cmd } elseif ($cfg.kokoro_python) { $cfg.kokoro_python } else { 'python' }

# Speed is one number across every engine, 1.0 being normal, because each engine
# expresses it differently (Kokoro a multiplier, edge-tts a percentage, SAPI a
# -10..10 scale). The engines convert it; the user sees one scale.
function Get-DefaultSpeed ($engine) {
  if ($cfg.voice_speed) { return [double]$cfg.voice_speed }
  switch ($engine) {
    'kokoro' { if ($cfg.kokoro_speed) { return [double]$cfg.kokoro_speed } else { return 1.15 } }
    'edge'   {
      if ($cfg.edge_rate -and ($cfg.edge_rate -match '^([+-]?\d+)%$')) { return 1 + ([double]$matches[1] / 100) }
      return 1.15
    }
    'native' { return 1.2 }
    default  { return 1.0 }
  }
}

# What the reply will actually be spoken with, and where each part came from.
function Get-VoiceName ($engine) {
  switch ($engine) {
    'kokoro'     { if ($cfg.kokoro_voice) { $cfg.kokoro_voice } else { 'bf_emma' } }
    'edge'       { if ($cfg.edge_voice)   { $cfg.edge_voice }   else { 'en-US-AvaNeural' } }
    'elevenlabs' { if ($cfg.eleven_voice) { $cfg.eleven_voice } else { 'JBFqnCBsd6RMkjVDRZzb' } }
    default      { if ($cfg.native_voice) { $cfg.native_voice } else { 'system default' } }
  }
}

# Kokoro's catalogue lives in one JSON file shared with the installer, so the ids
# and grades cannot drift between what you can install and what you can switch to.
function Get-KokoroVoices {
  $p = Join-Path $root 'lib\kokoro-voices.json'
  if (-not (Test-Path $p)) { return @() }
  try { return @(Get-Content $p -Raw | ConvertFrom-Json) } catch { return @() }
}

$raw = [Console]::In.ReadToEnd()
try { $j = $raw | ConvertFrom-Json } catch { $j = $null }
if ($j) {
  $sid    = [string]$j.session_id
  $prompt = [string]$j.prompt
} else {
  # This event carries last_assistant_message too, so it is exposed to the same
  # malformed-JSON bug as the Stop hook (openai/codex#23784). Salvage rather than
  # lose the session id, which would break the voice commands.
  $sid = ''; $prompt = ''
  $getter = Join-Path $root 'lib\json-get.mjs'
  if ((Test-Path $getter) -and -not [string]::IsNullOrWhiteSpace($raw)) {
    $prevEnc = $OutputEncoding
    $OutputEncoding = New-Object Text.UTF8Encoding $false
    # -join because PowerShell hands back multi-line output as an array of lines.
    $sid    = (($raw | node $getter session_id) -join '').Trim()
    $prompt = ($raw | node $getter prompt) -join "`n"
    $OutputEncoding = $prevEnc
  }
}

$globalOn = Join-Path $state 'voice-on'
$onFlag   = if ($sid) { Join-Path $state "on.$sid" }
$offFlag  = if ($sid) { Join-Path $state "off.$sid" }
$textFlag = if ($sid) { Join-Path $state "text.$sid" }
$engFlag  = if ($sid) { Join-Path $state "engine.$sid" }
$spdFlag  = if ($sid) { Join-Path $state "speed.$sid" }

# --- 1. in-session commands ---
$cmd = ($prompt.Trim().ToLower()) -replace '^[\\/]', ''

# voice engine <name> | voice engine default: pick a different engine for this
# session only, so two windows can use different voices at the same time.
if ($sid -and $cmd -match '^voice engine\b(.*)$') {
  $arg = $matches[1].Trim()
  if (-not $arg -or $arg -eq 'default') {
    Remove-Item $engFlag -Force -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine("agent-voice: engine override cleared; this session uses the default ($cfgEngine).")
  }
  elseif ($ENGINES -contains $arg) {
    Set-Content -Path $engFlag -Value $arg -NoNewline
    $note = ''
    if ($arg -eq 'elevenlabs' -and -not (Test-Path (Join-Path $root 'elevenlabs-key'))) {
      $note = ' (no API key stored, so it will fall back to the native voice)'
    }
    if ($arg -eq 'kokoro') {
      # Warm the model now so the first reply on the new engine is not slow.
      $serve = Join-Path $root 'kokoro_serve.py'
      if (Test-Path $serve) { Start-Process -FilePath $cfgPython -ArgumentList @($serve, $state) -WindowStyle Hidden }
      $note = ' (warming the model now)'
    }
    [Console]::Error.WriteLine("agent-voice: engine for this session is now $arg$note")
  }
  else {
    [Console]::Error.WriteLine("agent-voice: unknown engine '$arg'. Choose from: $($ENGINES -join ', '), or 'default'.")
  }
  exit 2
}

# The engine in effect for this session, which the voice commands below act on.
$curEngine = if ($sid -and (Test-Path $engFlag)) { (Get-Content $engFlag -Raw).Trim() } else { $cfgEngine }
$vceFlag   = if ($sid) { Join-Path $state "voice.$curEngine.$sid" }

# voice help: every command in one place.
if ($sid -and $cmd -eq 'voice help') {
  @(
    'agent-voice commands (each affects this session only):',
    '  voice on                summary plus spoken audio',
    '  voice text              summary only, no audio',
    '  voice off               back to normal replies',
    '  voice status            what this session will use right now',
    '  voice engine <name>     edge | kokoro | elevenlabs | native',
    '  voice model <id>        change the voice itself, e.g. voice model af_heart',
    '  voice speed <n>         0.5 to 2.0, where 1.0 is normal',
    '  voice list              voices available for the current engine',
    '  voice help              this list',
    '',
    "  Add 'default' to reset one, for example: voice speed default",
    '  Stop speech immediately: Ctrl+Alt+S'
  ) | ForEach-Object { [Console]::Error.WriteLine($_) }
  exit 2
}

# voice list: what you can switch to on the engine in effect.
if ($sid -and $cmd -match '^voice list\b(.*)$') {
  $showAll = $matches[1].Trim() -eq 'all'
  if ($curEngine -eq 'kokoro') {
    $voices = Get-KokoroVoices
    if (-not $showAll) { $voices = @($voices | Where-Object { $_.lang -in @('British', 'American') }) }
    [Console]::Error.WriteLine("agent-voice: Kokoro voices ($($voices.Count) shown). Grades are the model's own.")
    foreach ($v in $voices) {
      [Console]::Error.WriteLine(("  {0,-14} {1,-11} {2,-7} grade {3}" -f $v.id, $v.lang, $v.sex, $v.grade))
    }
    if (-not $showAll) { [Console]::Error.WriteLine("  'voice list all' also shows the other 7 languages.") }
    [Console]::Error.WriteLine('  Switch with: voice model <id>')
  }
  elseif ($curEngine -eq 'edge') {
    [Console]::Error.WriteLine('agent-voice: common edge-tts voices:')
    foreach ($v in @('en-GB-SoniaNeural   British female', 'en-GB-RyanNeural    British male',
                     'en-US-AvaNeural     American female', 'en-US-AndrewNeural  American male')) {
      [Console]::Error.WriteLine("  $v")
    }
    [Console]::Error.WriteLine('  Full list: python -m edge_tts --list-voices')
    [Console]::Error.WriteLine('  Switch with: voice model <id>')
  }
  elseif ($curEngine -eq 'elevenlabs') {
    [Console]::Error.WriteLine('agent-voice: ElevenLabs voice ids come from your own account at elevenlabs.io/voice-library.')
    [Console]::Error.WriteLine('  Switch with: voice model <voice-id>')
  }
  else {
    [Console]::Error.WriteLine('agent-voice: the native engine uses the voice built into the OS.')
    [Console]::Error.WriteLine('  Windows: change it in Settings > Time & language > Speech.')
  }
  exit 2
}

# voice model <id> (voice voice <id> reads naturally too): change the voice itself
# for this session. Stored per engine, so switching engine does not carry a Kokoro
# id over to edge-tts, where it would mean nothing.
if ($sid -and $cmd -match '^voice (?:model|voice)\b(.*)$') {
  $arg = $matches[1].Trim()
  if (-not $arg -or $arg -eq 'default') {
    Remove-Item $vceFlag -Force -ErrorAction SilentlyContinue
    [Console]::Error.WriteLine("agent-voice: voice override cleared; $curEngine is back to $(Get-VoiceName $curEngine)")
  }
  else {
    $ok = $true
    if ($curEngine -eq 'kokoro') {
      $known = @(Get-KokoroVoices | ForEach-Object { $_.id })
      if ($known.Count -gt 0 -and $known -notcontains $arg) { $ok = $false }
    }
    if ($ok) {
      Set-Content -Path $vceFlag -Value $arg -NoNewline
      [Console]::Error.WriteLine("agent-voice: voice for this session is now $arg (engine $curEngine)")
    } else {
      [Console]::Error.WriteLine("agent-voice: '$arg' is not a Kokoro voice. Try 'voice list' to see them.")
    }
  }
  exit 2
}

# voice speed <n>: how fast the summary is read, in this session only. One scale
# across all engines, 1.0 normal, because spoken summaries are often the thing you
# want to get through quickly.
if ($sid -and $cmd -match '^voice speed\b(.*)$') {
  $arg = $matches[1].Trim()
  if (-not $arg -or $arg -eq 'default') {
    Remove-Item $spdFlag -Force -ErrorAction SilentlyContinue
    $eng = if (Test-Path $engFlag) { (Get-Content $engFlag -Raw).Trim() } else { $cfgEngine }
    [Console]::Error.WriteLine("agent-voice: speed override cleared; back to $(Get-DefaultSpeed $eng)x")
  }
  else {
    $val = 0.0
    if ([double]::TryParse($arg, [ref]$val) -and $val -ge $SPEED_MIN -and $val -le $SPEED_MAX) {
      Set-Content -Path $spdFlag -Value $val -NoNewline
      [Console]::Error.WriteLine("agent-voice: speed for this session is now ${val}x (1.0 is normal)")
    } else {
      [Console]::Error.WriteLine("agent-voice: speed must be a number between $SPEED_MIN and $SPEED_MAX, for example 'voice speed 1.5'. Use 'voice speed default' to reset.")
    }
  }
  exit 2
}

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
      $engName  = if ($sid -and (Test-Path $engFlag)) { (Get-Content $engFlag -Raw).Trim() } else { $cfgEngine }
      $engFrom  = if ($sid -and (Test-Path $engFlag)) { 'this session' } else { 'default' }
      $spdVal   = if ($sid -and (Test-Path $spdFlag)) { (Get-Content $spdFlag -Raw).Trim() } else { Get-DefaultSpeed $engName }
      $spdFrom  = if ($sid -and (Test-Path $spdFlag)) { 'this session' } else { 'default' }
      $vceName = if ($sid -and (Test-Path $vceFlag)) { "$((Get-Content $vceFlag -Raw).Trim()) (this session)" }
                 else { "$(Get-VoiceName $engName) (default)" }
      [Console]::Error.WriteLine("agent-voice: $st")
      [Console]::Error.WriteLine("  engine  $engName ($engFrom)")
      [Console]::Error.WriteLine("  voice   $vceName")
      [Console]::Error.WriteLine("  speed   ${spdVal}x ($spdFrom, 1.0 is normal)")
      if ($engName -eq 'elevenlabs') {
        [Console]::Error.WriteLine('  note    ElevenLabs ignores speed; it has no rate control in this integration.')
      }
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
