# agent-voice Stop hook (Windows). Speaks the <spoken> block for the active session,
# using the engine chosen at install time. Always falls back to offline SAPI so
# it degrades to "sounds basic" rather than "silent".

$ErrorActionPreference = 'SilentlyContinue'
$root  = Join-Path $env:USERPROFILE '.agent-voice'
$state = Join-Path $root 'state'

# --- load config (simple key=value file) ---
$cfg = @{}
$cfgFile = Join-Path $root 'config'
if (Test-Path $cfgFile) {
  Get-Content $cfgFile | ForEach-Object {
    if ($_ -match '^\s*([^#=]+?)\s*=\s*(.*)$') { $cfg[$matches[1].Trim()] = $matches[2].Trim() }
  }
}
$engine = if ($cfg.engine) { $cfg.engine } else { 'edge' }

# Which interpreter to use. Bare "python" resolves against the PATH of whichever
# agent launched the hook, which is not necessarily the one the dependencies were
# installed into: a project venv earlier on PATH produces a missing-dependency
# exit and a silent drop to the robotic voice. The installer records the
# interpreter it verified. kokoro_python is accepted as an older spelling.
$pyExe = if ($cfg.python_cmd) { $cfg.python_cmd } elseif ($cfg.kokoro_python) { $cfg.kokoro_python } else { 'python' }

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

# Fast path: parse the payload. Slow path: Codex on Windows can send malformed JSON
# when the reply contains non-ASCII text (openai/codex#23784), so rather than going
# silent, salvage the two fields we need with the shared Node helper.
$j = $null
try { $j = $raw | ConvertFrom-Json } catch { $j = $null }
if ($j) {
  $sid = [string]$j.session_id
  $msg = [string]$j.last_assistant_message
} else {
  $getter = Join-Path $root 'lib\json-get.mjs'
  if (-not (Test-Path $getter)) { exit 0 }
  $prevEnc = $OutputEncoding
  $OutputEncoding = New-Object Text.UTF8Encoding $false
  # -join because PowerShell hands back multi-line output as an array of lines.
  $sid = (($raw | node $getter session_id) -join '').Trim()
  $msg = ($raw | node $getter last_assistant_message) -join "`n"
  $OutputEncoding = $prevEnc
}

$globalOn = Join-Path $state 'voice-on'
$onFlag   = if ($sid) { Join-Path $state "on.$sid" }
$offFlag  = if ($sid) { Join-Path $state "off.$sid" }
$textFlag = if ($sid) { Join-Path $state "text.$sid" }

# Active for this session?
$active = $false
if ($sid -and (Test-Path $onFlag)) { $active = $true }
elseif ((Test-Path $globalOn) -and -not ($sid -and (Test-Path $offFlag))) { $active = $true }
if (-not $active) { exit 0 }

# Text-only mode: the summary is injected, but we produce no audio.
if ($sid -and (Test-Path $textFlag)) { exit 0 }

# A per-session engine override ("voice engine kokoro") beats the installed default,
# so different windows can speak with different engines at the same time.
if ($sid) {
  $engFlag = Join-Path $state "engine.$sid"
  if (Test-Path $engFlag) {
    $override = (Get-Content $engFlag -Raw).Trim()
    if ($override) { $engine = $override }
  }
}

# Speed is one number across every engine, 1.0 being normal. Each engine below
# converts it to whatever it actually wants, so the user only ever sees one scale.
$speedMul = $null
if ($sid) {
  $spdFlag = Join-Path $state "speed.$sid"
  if (Test-Path $spdFlag) {
    $v = 0.0
    if ([double]::TryParse((Get-Content $spdFlag -Raw).Trim(), [ref]$v)) { $speedMul = $v }
  }
}
if ($null -eq $speedMul -and $cfg.voice_speed) {
  $v = 0.0
  if ([double]::TryParse($cfg.voice_speed, [ref]$v)) { $speedMul = $v }
}

# Kimi Code's Stop payload has no last_assistant_message at all, so recover the
# reply from its session transcript. Only runs when the field is genuinely absent,
# which leaves Claude Code and Codex untouched.
if ([string]::IsNullOrWhiteSpace($msg) -and $sid -like 'session_*') {
  $kimi = Join-Path $root 'lib\kimi-last-text.mjs'
  if (Test-Path $kimi) { $msg = (node $kimi $sid $env:USERPROFILE) -join "`n" }
}

if ([string]::IsNullOrWhiteSpace($msg)) { exit 0 }
# Take the LAST block, and require its content not to contain another opening tag.
# Both matter: a naive non-greedy match runs from the first <spoken> to the first
# </spoken>, so one mistyped closing tag earlier in the reply makes it span two
# blocks and read the entire reply aloud.
$blocks = [regex]::Matches($msg, '(?s)<spoken>((?:(?!<spoken>).)*?)</spoken>')
if ($blocks.Count -eq 0) { exit 0 }
$text = ($blocks[$blocks.Count - 1].Groups[1].Value -replace '[`*#_>|]', '') -replace '\s+', ' '
$text = $text.Trim()
if ([string]::IsNullOrWhiteSpace($text)) { exit 0 }

$tag     = if ($sid) { $sid } else { 'nosession' }
$pidFile = Join-Path $state "speak.$tag.pid"
$mp3     = Join-Path $state "say.$tag.mp3"
$wav     = Join-Path $state "say.$tag.wav"
$alias   = "ccvoice$PID"

# Cut off this session's previous turn if it is still speaking.
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile
  if ($old) { Stop-Process -Id $old -Force }
}
$PID | Set-Content $pidFile

# MCI player for MP3. Returns $true only if playback actually happened: MCI fails
# silently otherwise (notably rc=304 when the path exceeds ~128 chars), and a
# silent failure must fall through to SAPI rather than pass for success.
function Play-Mp3 ($file, $al) {
  Add-Type -Name Mci -Namespace Native -MemberDefinition @'
[DllImport("winmm.dll", CharSet = CharSet.Auto)]
public static extern int mciSendString(string cmd, System.Text.StringBuilder ret, int len, System.IntPtr hwnd);
'@
  if ([Native.Mci]::mciSendString("open `"$file`" type mpegvideo alias $al", $null, 0, [IntPtr]::Zero) -ne 0) { return $false }
  $rc = [Native.Mci]::mciSendString("play $al wait", $null, 0, [IntPtr]::Zero)
  [Native.Mci]::mciSendString("close $al", $null, 0, [IntPtr]::Zero) | Out-Null
  return ($rc -eq 0)
}

# WAV playback via SoundPlayer, not MCI: it plays WAV natively, blocks until the
# audio finishes, and has none of MCI's path-length limits.
function Play-Wav ($file) {
  try {
    $player = New-Object System.Media.SoundPlayer $file
    $player.PlaySync()
    $player.Dispose()
    return $true
  } catch { return $false }
}

$spoke = $false
Remove-Item $mp3 -Force
Remove-Item $wav -Force

if ($engine -eq 'edge') {
  $voice = if ($cfg.edge_voice) { $cfg.edge_voice } else { 'en-US-AvaNeural' }
  $rate  = if ($cfg.edge_rate)  { $cfg.edge_rate }  else { '+15%' }
  # edge-tts wants a percentage delta, so 1.25x becomes +25%.
  if ($null -ne $speedMul) {
    $pct  = [int][Math]::Round(($speedMul - 1) * 100)
    $rate = if ($pct -ge 0) { "+$pct%" } else { "$pct%" }
  }
  & $pyExe -m edge_tts --text "$text" --voice $voice --rate=$rate --write-media "$mp3" 2>$null
  if ((Test-Path $mp3) -and ((Get-Item $mp3).Length -gt 500)) { $spoke = Play-Mp3 $mp3 $alias }
}
elseif ($engine -eq 'kokoro') {
  # Offline neural voice. ~1.7s once the warm daemon is up; the client starts one
  # if it is not. The very first call ever also downloads weights, and that turn
  # takes ~12s or falls back to SAPI.
  $voice = if ($cfg.kokoro_voice) { $cfg.kokoro_voice } else { 'bf_emma' }
  $speed = if ($null -ne $speedMul) { $speedMul } elseif ($cfg.kokoro_speed) { $cfg.kokoro_speed } else { '1.15' }
  $py    = Join-Path $root 'kokoro-tts.py'
  if (Test-Path $py) {
    $prev = $OutputEncoding
    $OutputEncoding = New-Object Text.UTF8Encoding $false
    $text | & $pyExe $py $wav $voice $speed 2>$null
    $OutputEncoding = $prev
    if ((Test-Path $wav) -and ((Get-Item $wav).Length -gt 500)) { $spoke = Play-Wav $wav }
  }
}
elseif ($engine -eq 'elevenlabs') {
  $keyFile = Join-Path $root 'elevenlabs-key'
  $key = if (Test-Path $keyFile) { (Get-Content $keyFile -Raw).Trim() } else { '' }
  $voice = if ($cfg.eleven_voice) { $cfg.eleven_voice } else { 'JBFqnCBsd6RMkjVDRZzb' }
  $model = if ($cfg.eleven_model) { $cfg.eleven_model } else { 'eleven_flash_v2_5' }
  if ($key) {
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      $body = @{ text = $text; model_id = $model; voice_settings = @{ stability = 0.5; similarity_boost = 0.75; style = 0.0; use_speaker_boost = $true } } | ConvertTo-Json -Depth 5 -Compress
      $bytes = [Text.Encoding]::UTF8.GetBytes($body)
      $uri = "https://api.elevenlabs.io/v1/text-to-speech/$voice`?output_format=mp3_44100_128"
      Invoke-WebRequest -Uri $uri -Method Post -Headers @{ 'xi-api-key' = $key } -ContentType 'application/json' -Body $bytes -OutFile $mp3 -TimeoutSec 20 -UseBasicParsing
      if ((Test-Path $mp3) -and ((Get-Item $mp3).Length -gt 500)) { $spoke = Play-Mp3 $mp3 $alias }
    } catch { $spoke = $false }
  }
}

# Fallback: offline Windows SAPI.
if (-not $spoke) {
  Add-Type -AssemblyName System.Speech
  $sapi = New-Object System.Speech.Synthesis.SpeechSynthesizer
  # SAPI's scale is -10..10 with 0 normal, so 1.2x lands on its long-standing default of 2.
  $sapi.Rate = if ($null -ne $speedMul) { [Math]::Max(-10, [Math]::Min(10, [int][Math]::Round(($speedMul - 1) * 10))) } else { 2 }
  $sapi.Speak($text)
  $sapi.Dispose()
}

Remove-Item $mp3 -Force
Remove-Item $wav -Force
Remove-Item $pidFile
exit 0
