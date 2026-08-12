# agent-voice UserPromptSubmit hook (Windows).
#   1. Intercepts the in-session commands: voice on / voice text / voice off /
#      voice status / voice engine <name> (each affects only the session it is
#      typed in, keyed on session_id; the hook carries it out and hands the reply
#      to the model to print, since that is the only output every client shows).
#   2. Otherwise, when voice is active for this session, injects the instruction that
#      asks Claude to end its reply with a plain-language <spoken> summary.

$ErrorActionPreference = 'SilentlyContinue'
$root  = Join-Path $env:USERPROFILE '.agent-voice'
$state = Join-Path $root 'state'
if (-not (Test-Path $state)) {
  New-Item -ItemType Directory -Force -Path $state | Out-Null
  # Owner-only ACL: kokoro.port in here carries the daemon token.
  $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  icacls $state /inheritance:r /grant:r "*${me}:(OI)(CI)F" | Out-Null
}

$ENGINES = @('edge', 'kokoro', 'elevenlabs', 'native')
$SPEED_MIN = 0.5
$SPEED_MAX = 2.0

# A command's reply is collected here and emitted by Send-Out below.
$script:outLines = New-Object System.Collections.Generic.List[string]
function Add-Out ($line) { $script:outLines.Add([string]$line) }

# Off unless you put debug=1 in ~/.agent-voice/config. When a client shows nothing
# this answers the first question in one attempt: did the hook run and produce a
# reply, or not run at all? It stays off by default because it would otherwise
# write part of every prompt to disk, which sits badly with a tool whose whole
# claim is that your prompts go nowhere.
function Write-HookLog ($line) {
  if (-not $cfg -or $cfg['debug'] -ne '1') { return }
  try {
    Add-Content -Path (Join-Path $state 'hook.log') -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $line)
  } catch { }
}

function Send-Out {
  $text = ($script:outLines -join "`n")
  Write-HookLog ("command '$cmd' replied with $($text.Length) chars")
  Set-Content -Path (Join-Path $state 'last-reply.txt') -Value $text -ErrorAction SilentlyContinue

  # Getting this text on screen turned out to be the hard part. stderr with exit 2
  # is documented to show the user and works in a terminal, but the VS Code
  # extension renders none of it: not stderr, not "reason" from a block decision,
  # not "systemMessage". Confirmed from the hook log, where the command fires and
  # replies and the user still sees nothing.
  #
  # So the reply is handed to the model as context instead, with an instruction to
  # print it verbatim. That costs one cheap turn, but the model's reply is the one
  # channel every client displays, which is the whole point.
  $instruction = @"
The user typed the agent-voice command "$cmd". The hook has already carried it out;
there is nothing for you to run or change. Output the block below exactly as it is,
inside a code fence, and write nothing else at all: no preamble, no summary, no
<spoken> block.

$text
"@
  $payload = [ordered]@{
    hookSpecificOutput = [ordered]@{
      hookEventName    = 'UserPromptSubmit'
      additionalContext = $instruction
    }
    systemMessage = $text
  }
  [Console]::Out.WriteLine(($payload | ConvertTo-Json -Compress -Depth 4))
  # Also on stderr, for terminals that show that instead of parsing the JSON.
  [Console]::Error.WriteLine($text)
  exit 0
}

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
# The session id lands in file paths, so clamp anything outside [A-Za-z0-9_-]
# to the shared-state id rather than letting ..\ traverse (R-13).
if ($sid -and $sid -notmatch '^[A-Za-z0-9_-]+$') { $sid = 'nosession' }

$globalOn = Join-Path $state 'voice-on'
$onFlag   = if ($sid) { Join-Path $state "on.$sid" }
$offFlag  = if ($sid) { Join-Path $state "off.$sid" }
$textFlag = if ($sid) { Join-Path $state "text.$sid" }
$engFlag  = if ($sid) { Join-Path $state "engine.$sid" }
$spdFlag  = if ($sid) { Join-Path $state "speed.$sid" }

# --- 1. in-session commands ---
$cmd = ($prompt.Trim().ToLower()) -replace '^[\\/]', ''
Write-HookLog ("fired: sid='$sid' prompt='" + $cmd.Substring(0, [Math]::Min(40, $cmd.Length)) + "'")

# voice engine: bare shows a numbered list to choose from, since picking a number
# beats remembering and typing a name. A name still works, and so does 'default'.
if ($sid -and $cmd -match '^voice engine\b(.*)$') {
  $arg = $matches[1].Trim()
  $cur = if (Test-Path $engFlag) { (Get-Content $engFlag -Raw).Trim() } else { $cfgEngine }

  # A bare number selects from the list below; the order is fixed so it is stable.
  if ($arg -match '^\d+$') {
    $i = [int]$arg
    if ($i -ge 1 -and $i -le $ENGINES.Count) { $arg = $ENGINES[$i - 1] }
  }

  if (-not $arg) {
    Add-Out ('agent-voice: choose an engine by number or name:')
    for ($i = 0; $i -lt $ENGINES.Count; $i++) {
      $mark = if ($ENGINES[$i] -eq $cur) { '*' } else { ' ' }
      $desc = switch ($ENGINES[$i]) {
        'edge'       { 'free, natural, summary text sent to Microsoft' }
        'kokoro'     { 'free, natural, fully local, 54 voices' }
        'elevenlabs' { 'best quality, needs your API key' }
        default      { 'robotic, no dependencies, no network' }
      }
      Add-Out (("  {0} {1}. {2,-11} {3}" -f $mark, ($i + 1), $ENGINES[$i], $desc))
    }
    Add-Out ("  * is in use now. Choose with: voice engine 2   (or: voice engine kokoro)")
    Send-Out
  }
  if ($arg -eq 'default') {
    Remove-Item $engFlag -Force -ErrorAction SilentlyContinue
    Add-Out ("agent-voice: engine override cleared; this session uses the default ($cfgEngine).")
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
    Add-Out ("agent-voice: engine for this session is now $arg$note")
  }
  else {
    Add-Out ("agent-voice: unknown engine '$arg'. Choose from: $($ENGINES -join ', '), or 'default'.")
  }
  Send-Out
}

# The engine in effect for this session, which the voice commands below act on.
$curEngine = if ($sid -and (Test-Path $engFlag)) { (Get-Content $engFlag -Raw).Trim() } else { $cfgEngine }
$vceFlag   = if ($sid) { Join-Path $state "voice.$curEngine.$sid" }

# voice stop: kill speech from inside the session. The hotkey is faster where it
# exists, but macOS has no hotkey by default, and typing this needs no OS
# integration at all. Works everywhere, including over SSH.
if ($sid -and ($cmd -eq 'voice stop' -or $cmd -eq 'shush' -or $cmd -eq 'stop voice')) {
  $shush = Join-Path $root 'shush.ps1'
  if (Test-Path $shush) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $shush *> $null
    Add-Out ('agent-voice: speech stopped.')
  } else {
    Add-Out ('agent-voice: shush.ps1 is missing; re-run the installer.')
  }
  Send-Out
}

# voice help: every command in one place.
if ($sid -and $cmd -eq 'voice help') {
  @(
    'agent-voice commands (each affects this session only):',
    '  voice on                summary plus spoken audio',
    '  voice text              summary only, no audio',
    '  voice off               back to normal replies',
    '  voice stop              stop speech now (also: shush)',
    '  voice status            what this session will use right now',
    '  voice engine            list engines, then: voice engine 2',
    '  voice model             list voices, then: voice model 9',
    '  voice preview <n>       hear a voice without switching to it',
    '  voice pick              browse voices with arrows and P, in a new window',
    '  voice speed             list speeds, then: voice speed 1.5',
    '  voice list              same as voice model, lists what is available',
    '  voice help              this list',
    '',
    "  Add 'default' to reset one, for example: voice speed default",
    '  Stop speech immediately: Ctrl+Alt+S, or type: voice stop'
  ) | ForEach-Object { Add-Out $_ }
  Send-Out
}

# The voices you can pick on the engine in effect, printed with numbers so that
# choosing one is 'voice model 9' rather than recalling an exact id. Numbers index
# the full catalogue, which is ordered English first, so they stay stable whether
# or not the other languages are on screen.
function Show-Voices ($engine, $showAll) {
  if ($engine -eq 'kokoro') {
    $all = Get-KokoroVoices
    $shown = if ($showAll) { $all } else { @($all | Where-Object { $_.lang -in @('British', 'American') }) }
    $cur = if ($sid -and (Test-Path $vceFlag)) { (Get-Content $vceFlag -Raw).Trim() } else { Get-VoiceName $engine }
    Add-Out ("agent-voice: Kokoro voices ($($shown.Count) of $($all.Count)). Grades are the model's own.")
    for ($i = 0; $i -lt $all.Count; $i++) {
      if ($shown -notcontains $all[$i]) { continue }
      $mark = if ($all[$i].id -eq $cur) { '*' } else { ' ' }
      Add-Out (("  {0} {1,2}. {2,-14} {3,-11} {4,-7} grade {5}" -f $mark, ($i + 1), $all[$i].id, $all[$i].lang, $all[$i].sex, $all[$i].grade))
    }
    if (-not $showAll) { Add-Out ("  'voice model all' adds the other 7 languages.") }
    Add-Out ('  * is in use now. Choose with: voice model 9   (or: voice model af_heart)')
  }
  elseif ($engine -eq 'edge') {
    $list = @('en-GB-SoniaNeural|British female', 'en-GB-RyanNeural|British male',
              'en-US-AvaNeural|American female', 'en-US-AndrewNeural|American male',
              'en-AU-NatashaNeural|Australian female', 'en-IE-EmilyNeural|Irish female')
    $cur = if ($sid -and (Test-Path $vceFlag)) { (Get-Content $vceFlag -Raw).Trim() } else { Get-VoiceName $engine }
    Add-Out ('agent-voice: common edge-tts voices:')
    for ($i = 0; $i -lt $list.Count; $i++) {
      $p = $list[$i].Split('|')
      $mark = if ($p[0] -eq $cur) { '*' } else { ' ' }
      Add-Out (("  {0} {1,2}. {2,-20} {3}" -f $mark, ($i + 1), $p[0], $p[1]))
    }
    Add-Out ('  Hundreds more: python -m edge_tts --list-voices')
    Add-Out ('  Choose with: voice model 3   (or: voice model en-GB-SoniaNeural)')
  }
  elseif ($engine -eq 'elevenlabs') {
    Add-Out ('agent-voice: ElevenLabs voice ids come from your own account at elevenlabs.io/voice-library.')
    Add-Out ('  There is no list to number here, so paste the id: voice model <voice-id>')
  }
  else {
    Add-Out ('agent-voice: the native engine uses the voice built into the OS.')
    Add-Out ('  Windows: change it in Settings > Time & language > Speech.')
  }
}

# The numbered edge-tts shortlist, kept next to the display so they cannot diverge.
$EDGE_SHORTLIST = @('en-GB-SoniaNeural', 'en-GB-RyanNeural', 'en-US-AvaNeural',
                    'en-US-AndrewNeural', 'en-AU-NatashaNeural', 'en-IE-EmilyNeural')

# voice pick: the same arrow-key picker the installer uses, in its own console
# window, because this hook cannot read keystrokes itself. Enter writes the
# session's voice and the window closes.
if ($sid -and $cmd -eq 'voice pick') {
  $picker = Join-Path $root 'pick-voice.ps1'
  if (-not (Test-Path $picker)) {
    Add-Out ('agent-voice: pick-voice.ps1 is missing; re-run the installer.')
  } elseif ($curEngine -ne 'kokoro') {
    Add-Out ("agent-voice: the picker only covers Kokoro, the one engine whose voices can be auditioned offline.")
    Add-Out ("  You are on '$curEngine'. Switch with 'voice engine kokoro', or use 'voice model' for a list.")
  } else {
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $picker,
      '-SessionId', $sid, '-Engine', $curEngine, '-Root', $root
    ) | Out-Null
    Add-Out ('agent-voice: opened the voice picker in a new window. Arrows to move, P to hear, Enter to choose.')
  }
  Send-Out
}

# voice preview <n|id>: hear a voice without switching to it. Backgrounded so the
# hook returns at once rather than holding up the prompt while audio plays.
if ($sid -and $cmd -match '^voice preview\b(.*)$') {
  $arg = $matches[1].Trim()
  if ($curEngine -ne 'kokoro') {
    Add-Out ("agent-voice: preview only works on Kokoro, which synthesises locally. You are on '$curEngine'.")
    Send-Out
  }
  $all = Get-KokoroVoices
  if ($arg -match '^\d+$') {
    $i = [int]$arg
    if ($i -ge 1 -and $i -le $all.Count) { $arg = $all[$i - 1].id }
  }
  if (-not $arg) {
    Add-Out ("agent-voice: say which one, for example 'voice preview 9'. Type 'voice model' for the list.")
  }
  elseif (@($all | ForEach-Object { $_.id }) -notcontains $arg) {
    Add-Out ("agent-voice: '$arg' is not a Kokoro voice. Type 'voice model' to see the list.")
  }
  else {
    $picker = Join-Path $root 'pick-voice.ps1'
    if (Test-Path $picker) {
      Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $picker, '-Preview', $arg, '-Root', $root
      ) | Out-Null
      Add-Out ("agent-voice: playing $arg. Switch to it with: voice model $arg")
    }
  }
  Send-Out
}

# voice list is kept as an alias for the bare listing.
if ($sid -and $cmd -match '^voice list\b(.*)$') {
  Show-Voices $curEngine ($matches[1].Trim() -eq 'all')
  Send-Out
}

# voice model: bare lists, a number or an id selects, 'default' clears. Stored per
# engine, so switching engine does not carry a Kokoro id over to edge-tts.
if ($sid -and $cmd -match '^voice (?:model|voice)\b(.*)$') {
  $arg = $matches[1].Trim()

  if (-not $arg -or $arg -eq 'all') {
    Show-Voices $curEngine ($arg -eq 'all')
    Send-Out
  }

  # A bare number selects from the list just shown.
  if ($arg -match '^\d+$') {
    $i = [int]$arg
    if ($curEngine -eq 'kokoro') {
      $all = Get-KokoroVoices
      if ($i -ge 1 -and $i -le $all.Count) { $arg = $all[$i - 1].id }
    }
    elseif ($curEngine -eq 'edge') {
      if ($i -ge 1 -and $i -le $EDGE_SHORTLIST.Count) { $arg = $EDGE_SHORTLIST[$i - 1] }
    }
  }

  if ($arg -eq 'default') {
    Remove-Item $vceFlag -Force -ErrorAction SilentlyContinue
    Add-Out ("agent-voice: voice override cleared; $curEngine is back to $(Get-VoiceName $curEngine)")
  }
  else {
    $ok = $true
    if ($curEngine -eq 'kokoro') {
      $known = @(Get-KokoroVoices | ForEach-Object { $_.id })
      if ($known.Count -gt 0 -and $known -notcontains $arg) { $ok = $false }
    }
    if ($ok) {
      Set-Content -Path $vceFlag -Value $arg -NoNewline
      Add-Out ("agent-voice: voice for this session is now $arg (engine $curEngine)")
    } else {
      Add-Out ("agent-voice: '$arg' is not a Kokoro voice. Type 'voice model' to see the list.")
    }
  }
  Send-Out
}

# voice speed <n>: how fast the summary is read, in this session only. One scale
# across all engines, 1.0 normal, because spoken summaries are often the thing you
# want to get through quickly.
if ($sid -and $cmd -match '^voice speed\b(.*)$') {
  $arg = $matches[1].Trim()

  # Listed as values rather than numbered, because 1 and 2 are themselves valid
  # speeds and a numbered menu would be ambiguous.
  if (-not $arg) {
    $cur = if (Test-Path $spdFlag) { (Get-Content $spdFlag -Raw).Trim() } else { Get-DefaultSpeed $curEngine }
    Add-Out ("agent-voice: speed is ${cur}x now. Any number from 0.5 to 2.0 works, for example:")
    foreach ($p in @('0.75|slower', '1.0|normal', '1.25|brisk', '1.5|fast', '1.75|very fast', '2.0|maximum')) {
      $q = $p.Split('|')
      $mark = if ([double]$q[0] -eq [double]$cur) { '*' } else { ' ' }
      Add-Out (("  {0} {1,-5} {2}" -f $mark, $q[0], $q[1]))
    }
    Add-Out ('  Choose with: voice speed 1.5')
    Send-Out
  }
  if ($arg -eq 'default') {
    Remove-Item $spdFlag -Force -ErrorAction SilentlyContinue
    $eng = if (Test-Path $engFlag) { (Get-Content $engFlag -Raw).Trim() } else { $cfgEngine }
    Add-Out ("agent-voice: speed override cleared; back to $(Get-DefaultSpeed $eng)x")
  }
  else {
    # Invariant culture, both parsing and writing: the default TryParse reads
    # "1.5" as 15 on a de-DE machine, and a culture-formatted write would put
    # "1,5" into the state file where every other reader expects a dot (R-17).
    $val = 0.0
    if ([double]::TryParse($arg, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$val) -and $val -ge $SPEED_MIN -and $val -le $SPEED_MAX) {
      $valText = $val.ToString([Globalization.CultureInfo]::InvariantCulture)
      Set-Content -Path $spdFlag -Value $valText -NoNewline
      Add-Out ("agent-voice: speed for this session is now ${valText}x (1.0 is normal)")
    } else {
      Add-Out ("agent-voice: speed must be a number between $SPEED_MIN and $SPEED_MAX, for example 'voice speed 1.5'. Use 'voice speed default' to reset.")
    }
  }
  Send-Out
}

if ($sid -and $cmd -in @('voice on', 'voice text', 'voice off', 'voice status')) {
  switch ($cmd) {
    'voice on' {
      New-Item -ItemType File -Force -Path $onFlag | Out-Null
      Remove-Item $offFlag, $textFlag -Force -ErrorAction SilentlyContinue
      Add-Out ('agent-voice: ON (summary + speech) for this session.')
    }
    'voice text' {
      New-Item -ItemType File -Force -Path $onFlag   | Out-Null
      New-Item -ItemType File -Force -Path $textFlag | Out-Null
      Remove-Item $offFlag -Force -ErrorAction SilentlyContinue
      Add-Out ('agent-voice: TEXT-ONLY summary (no audio) for this session.')
    }
    'voice off' {
      Remove-Item $onFlag, $textFlag -Force -ErrorAction SilentlyContinue
      New-Item -ItemType File -Force -Path $offFlag | Out-Null
      Add-Out ('agent-voice: OFF for this session.')
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
      Add-Out ("agent-voice: $st")
      Add-Out ("  engine  $engName ($engFrom)")
      Add-Out ("  voice   $vceName")
      Add-Out ("  speed   ${spdVal}x ($spdFrom, 1.0 is normal)")
      if ($engName -eq 'elevenlabs') {
        Add-Out ('  note    ElevenLabs ignores speed; it has no rate control in this integration.')
      }
    }
  }
  Send-Out
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
