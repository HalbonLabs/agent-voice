# agent-voice installer (Windows). Interactive: choose agents and a voice engine.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = 'Stop'
$src    = $PSScriptRoot
$target = Join-Path $env:USERPROFILE '.agent-voice'
$state  = Join-Path $target 'state'

Write-Host ''
Write-Host 'agent-voice installer (Windows)' -ForegroundColor Cyan
Write-Host '-------------------------------'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host 'ERROR: node not found on PATH. Node ships with these agents; install it first.' -ForegroundColor Red
  exit 1
}

# --- copy runtime files ---
New-Item -ItemType Directory -Force -Path $state | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $target 'lib') | Out-Null
Copy-Item (Join-Path $src 'core\windows\*') $target -Force
Copy-Item (Join-Path $src 'core\kokoro*.py') $target -Force
Copy-Item (Join-Path $src 'lib\*') (Join-Path $target 'lib') -Force
Write-Host ("Installed scripts to " + $target)

# --- choose agents ---
Write-Host ''
Write-Host 'Which agents should use agent-voice? (comma-separated)'
Write-Host '  claude   Claude Code       fully supported (summary + voice)'
Write-Host '  codex    Codex CLI         fully supported (summary + voice); please smoke-test'
Write-Host '  kimi     Kimi Code CLI     summary text supported; voice pending upstream support'
Write-Host ''
$agents = Read-Host 'Agents (Enter for claude)'
if ([string]::IsNullOrWhiteSpace($agents)) { $agents = 'claude' }
$agents = ($agents -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }) -join ','

# --- choose engine ---
Write-Host ''
Write-Host 'Choose a voice engine:'
Write-Host '  [1] edge-tts (Ava)   Free, natural. Short summary text sent to Microsoft. Needs Python. Quality: very good.'
Write-Host '  [2] ElevenLabs       Top quality. Uses your API key; summary text sent to ElevenLabs. Quality: best.'
Write-Host '  [3] Kokoro offline   Free, natural, fully private. Needs Python + ~300MB weights. Quality: good.'
Write-Host '  [4] Native offline   Fully private, no downloads, nothing to install. Quality: robotic.'
Write-Host ''
$choice = Read-Host 'Enter 1, 2, 3, or 4'

$cfg = @()
switch ($choice) {
  '2' {
    $sec = Read-Host 'Paste your ElevenLabs API key' -AsSecureString
    $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    Set-Content -Path (Join-Path $target 'elevenlabs-key') -Value $key -NoNewline
    $vid = Read-Host 'Voice ID (Enter for default British male "George")'
    if ([string]::IsNullOrWhiteSpace($vid)) { $vid = 'JBFqnCBsd6RMkjVDRZzb' }
    $cfg += 'engine=elevenlabs'; $cfg += "eleven_voice=$vid"; $cfg += 'eleven_model=eleven_flash_v2_5'
    Write-Host 'ElevenLabs selected. Key stored locally (not in any script).' -ForegroundColor Green
  }
  '3' {
    $kv = Read-Host 'Kokoro voice (Enter for British female "bf_emma")'
    if ([string]::IsNullOrWhiteSpace($kv)) { $kv = 'bf_emma' }
    $cfg += 'engine=kokoro'; $cfg += "kokoro_voice=$kv"; $cfg += 'kokoro_speed=1.15'
    Write-Host 'Kokoro offline selected. Nothing will leave this machine.' -ForegroundColor Green

    Write-Host 'Kokoro keeps a warm background process so replies start speaking in ~1.7s.' -ForegroundColor Gray
    Write-Host 'It uses about 1.7GB of RAM while resident, and exits after 15 idle minutes.' -ForegroundColor Gray

    # espeak-ng is not required: the espeakng-loader dependency bundles it.
    $have = $false
    try { python -c 'import kokoro, soundfile' *> $null; if ($LASTEXITCODE -eq 0) { $have = $true } } catch {}
    if (-not $have) {
      Write-Host 'Installing Kokoro (pip install --user kokoro soundfile) ... this pulls in PyTorch and takes a few minutes.'
      python -m pip install --user kokoro soundfile
    }

    # Warm up: pre-download the weights and the spaCy model that Kokoro's text
    # front-end fetches on first use, so the first spoken reply is not silent.
    Write-Host 'Downloading Kokoro voice weights (~300MB) and language model (one time) ...'
    $probe = Join-Path $state 'warmup.wav'
    'agent voice is ready' | python (Join-Path $target 'kokoro-tts.py') $probe $kv 1.15
    if ((Test-Path $probe) -and ((Get-Item $probe).Length -gt 500)) {
      Write-Host 'Kokoro is working.' -ForegroundColor Green
      Remove-Item $probe -Force -ErrorAction SilentlyContinue
    } else {
      Write-Host 'Kokoro could not synthesise yet. Voice will use the basic Windows one until this is fixed;' -ForegroundColor Yellow
      Write-Host 'run the pip install above by hand to see the error.' -ForegroundColor Yellow
    }
  }
  '4' {
    $cfg += 'engine=native'
    Write-Host 'Native offline selected.' -ForegroundColor Green
  }
  default {
    $cfg += 'engine=edge'; $cfg += 'edge_voice=en-US-AvaNeural'; $cfg += 'edge_rate=+15%'
    Write-Host 'edge-tts (Ava) selected.' -ForegroundColor Green
    $have = $false
    try { python -m edge_tts --version *> $null; if ($LASTEXITCODE -eq 0) { $have = $true } } catch {}
    if (-not $have) { Write-Host 'Installing edge-tts (pip install --user edge-tts) ...'; python -m pip install --user edge-tts }
  }
}
Set-Content -Path (Join-Path $target 'config') -Value ($cfg -join "`r`n")

# Global default ON so it works immediately.
New-Item -ItemType File -Force -Path (Join-Path $state 'voice-on') | Out-Null

# --- register hooks into the chosen agents ---
Write-Host ''
node (Join-Path $target 'lib\register.mjs') mode=install home=$env:USERPROFILE platform=win scripts=$target providers=$agents

# --- global stop hotkey: Ctrl+Alt+S ---
try {
  $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
  $lnk = Join-Path $startMenu 'agent-voice stop.lnk'
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut($lnk)
  $sc.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
  $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target\shush.ps1`""
  $sc.WorkingDirectory = $target
  $sc.WindowStyle = 7
  $sc.Hotkey = 'CTRL+ALT+S'
  $sc.Description = 'Stop agent-voice speech'
  $sc.Save()
  Write-Host 'Global stop hotkey installed: Ctrl+Alt+S'
} catch {
  Write-Host 'Could not create the stop hotkey (non-fatal). Use shush.cmd instead.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host 'Reload any open agent session so it picks up the hooks.'
Write-Host 'In any session, type:  voice on  |  voice text  |  voice off  |  voice status'
Write-Host 'Try another engine in one session only:  voice engine edge  (or kokoro/elevenlabs/native)'
Write-Host 'Stop speech anytime:   Ctrl+Alt+S'
