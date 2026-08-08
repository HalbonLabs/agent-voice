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

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
try { $j = $raw | ConvertFrom-Json } catch { exit 0 }
$sid = [string]$j.session_id

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

$msg = [string]$j.last_assistant_message
if ([string]::IsNullOrWhiteSpace($msg)) { exit 0 }
$m = [regex]::Match($msg, '(?s)<spoken>(.*?)</spoken>')
if (-not $m.Success) { exit 0 }
$text = ($m.Groups[1].Value -replace '[`*#_>|]', '') -replace '\s+', ' '
$text = $text.Trim()
if ([string]::IsNullOrWhiteSpace($text)) { exit 0 }

$tag     = if ($sid) { $sid } else { 'nosession' }
$pidFile = Join-Path $state "speak.$tag.pid"
$mp3     = Join-Path $state "say.$tag.mp3"
$alias   = "ccvoice$PID"

# Cut off this session's previous turn if it is still speaking.
if (Test-Path $pidFile) {
  $old = Get-Content $pidFile
  if ($old) { Stop-Process -Id $old -Force }
}
$PID | Set-Content $pidFile

function Play-Mp3 ($file, $al) {
  Add-Type -Name Mci -Namespace Native -MemberDefinition @'
[DllImport("winmm.dll", CharSet = CharSet.Auto)]
public static extern int mciSendString(string cmd, System.Text.StringBuilder ret, int len, System.IntPtr hwnd);
'@
  [Native.Mci]::mciSendString("open `"$file`" type mpegvideo alias $al", $null, 0, [IntPtr]::Zero) | Out-Null
  [Native.Mci]::mciSendString("play $al wait", $null, 0, [IntPtr]::Zero) | Out-Null
  [Native.Mci]::mciSendString("close $al", $null, 0, [IntPtr]::Zero) | Out-Null
}

$spoke = $false
Remove-Item $mp3 -Force

if ($engine -eq 'edge') {
  $voice = if ($cfg.edge_voice) { $cfg.edge_voice } else { 'en-US-AvaNeural' }
  $rate  = if ($cfg.edge_rate)  { $cfg.edge_rate }  else { '+15%' }
  python -m edge_tts --text "$text" --voice $voice --rate=$rate --write-media "$mp3" 2>$null
  if ((Test-Path $mp3) -and ((Get-Item $mp3).Length -gt 500)) { Play-Mp3 $mp3 $alias; $spoke = $true }
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
      if ((Test-Path $mp3) -and ((Get-Item $mp3).Length -gt 500)) { Play-Mp3 $mp3 $alias; $spoke = $true }
    } catch { $spoke = $false }
  }
}

# Fallback: offline Windows SAPI.
if (-not $spoke) {
  Add-Type -AssemblyName System.Speech
  $sapi = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $sapi.Rate = 2
  $sapi.Speak($text)
  $sapi.Dispose()
}

Remove-Item $mp3 -Force
Remove-Item $pidFile
exit 0
