# agent-voice installer (Windows). Interactive: choose agents and a voice engine.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = 'Stop'
$src    = $PSScriptRoot
$target = Join-Path $env:USERPROFILE '.agent-voice'
$state  = Join-Path $target 'state'

$avVersion = if (Test-Path (Join-Path $src 'VERSION')) { (Get-Content (Join-Path $src 'VERSION') -Raw).Trim() } else { 'unknown' }

Write-Host ''
Write-Host "agent-voice installer (Windows, $avVersion)" -ForegroundColor Cyan
Write-Host '-------------------------------'

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host 'ERROR: node not found on PATH. Node ships with these agents; install it first.' -ForegroundColor Red
  exit 1
}

# --- copy runtime files ---
New-Item -ItemType Directory -Force -Path $state | Out-Null
# Owner-only ACL on the state dir: kokoro.port in here carries the daemon token.
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
icacls $state /inheritance:r /grant:r "*${me}:(OI)(CI)F" | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $target 'lib') | Out-Null
Copy-Item (Join-Path $src 'core\windows\*') $target -Force
Copy-Item (Join-Path $src 'core\kokoro*.py') $target -Force
Copy-Item (Join-Path $src 'lib\*') (Join-Path $target 'lib') -Force
if (Test-Path (Join-Path $src 'VERSION')) { Copy-Item (Join-Path $src 'VERSION') $target -Force }
Write-Host ("Installed scripts to " + $target)

# --- choose agents ---
# Detect what is actually on this machine, and what is already wired up, so the
# list offers real choices instead of three names you have to recognise.
function Get-Agents {
  $h = $env:USERPROFILE
  $defs = @(
    @{ Key='claude'; Name='Claude Code';   Note='fully supported (summary + voice)';                            Dir='.claude';    Cfg='.claude\settings.json' },
    @{ Key='codex';  Name='Codex CLI';     Note='fully supported (summary + voice)'                            ;        Dir='.codex';     Cfg='.codex\hooks.json' },
    @{ Key='kimi';   Name='Kimi Code CLI'; Note='supported (summary + voice) via its session transcript';            Dir='.kimi-code'; Cfg='.kimi-code\config.toml' }
  )
  foreach ($d in $defs) {
    $cfgPath = Join-Path $h $d.Cfg
    $registered = $false
    if (Test-Path $cfgPath) { $registered = (Get-Content $cfgPath -Raw -ErrorAction SilentlyContinue) -match 'agent-voice' }
    [pscustomobject]@{
      Key        = $d.Key
      Name       = $d.Name
      Note       = $d.Note
      Installed  = [bool](Get-Command $d.Key -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $h $d.Dir))
      Registered = $registered
    }
  }
}

# Arrow-key checklist. Falls back to a typed list when stdin is not a real console
# (piped input, CI), because ReadKey cannot work there.
function Select-Agents ($items) {
  $sel = @{}
  foreach ($it in $items) { $sel[$it.Key] = $it.Registered -or ($it.Installed -and $it.Key -eq 'claude') }

  if ([Console]::IsInputRedirected) {
    Write-Host 'Which agents should use agent-voice? (comma-separated)'
    foreach ($it in $items) {
      $tag = if (-not $it.Installed) { '  [not detected]' } elseif ($it.Registered) { '  [already set up]' } else { '' }
      Write-Host ("  {0,-8} {1,-16} {2}{3}" -f $it.Key, $it.Name, $it.Note, $tag)
    }
    $typed = Read-Host 'Agents (Enter for claude)'
    if ([string]::IsNullOrWhiteSpace($typed)) { return 'claude' }
    return (($typed -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }) -join ',')
  }

  Write-Host 'Which agents should use agent-voice?'
  Write-Host 'Up/Down to move, Space to toggle, A for all, Enter to confirm.' -ForegroundColor DarkGray
  Write-Host ''
  $pos = 0
  $rows = $items.Count + 1          # the item lines, plus the "selected:" line
  $width = [Math]::Max(40, [Console]::WindowWidth - 1)
  $firstDraw = $true
  $hadCursor = $true
  try { $hadCursor = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { }
  try {
    while ($true) {
      # Move UP from wherever the cursor is now, rather than back to a row captured
      # before the loop: writing at the bottom of the buffer scrolls the console,
      # which shifts every absolute row and made each redraw land below the last.
      if ($firstDraw) { $firstDraw = $false }
      else { [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - $rows)) }

      for ($i = 0; $i -lt $items.Count; $i++) {
        $it = $items[$i]
        $cursor = if ($i -eq $pos) { '>' } else { ' ' }
        $box    = if ($sel[$it.Key]) { '[x]' } else { '[ ]' }
        $tag    = if (-not $it.Installed) { '  (not detected on this machine)' } elseif ($it.Registered) { '  (already set up)' } else { '' }
        $line   = "{0} {1} {2,-16} {3}{4}" -f $cursor, $box, $it.Name, $it.Note, $tag
        if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
        $colour = if (-not $it.Installed) { 'DarkGray' } elseif ($i -eq $pos) { 'Cyan' } else { 'Gray' }
        Write-Host ($line.PadRight($width)) -ForegroundColor $colour
      }
      $chosen = @($items | Where-Object { $sel[$_.Key] })
      $summary = "  selected: " + $(if ($chosen) { ($chosen.Key) -join ', ' } else { 'none yet' })
      if ($summary.Length -gt $width) { $summary = $summary.Substring(0, $width) }
      Write-Host ($summary.PadRight($width)) -ForegroundColor DarkGray

      $key = [Console]::ReadKey($true)
      switch ($key.Key) {
        'UpArrow'   { $pos = ($pos - 1 + $items.Count) % $items.Count }
        'DownArrow' { $pos = ($pos + 1) % $items.Count }
        'Spacebar'  { $sel[$items[$pos].Key] = -not $sel[$items[$pos].Key] }
        'Enter'     {
          $out = @($items | Where-Object { $sel[$_.Key] } | ForEach-Object { $_.Key })
          if ($out.Count -gt 0) { Write-Host ''; return ($out -join ',') }
        }
        default {
          if ($key.KeyChar -eq 'a' -or $key.KeyChar -eq 'A') {
            $allOn = -not (@($items | Where-Object { -not $sel[$_.Key] }).Count -gt 0)
            foreach ($it in $items) { $sel[$it.Key] = -not $allOn }
          }
        }
      }
    }
  } finally {
    try { [Console]::CursorVisible = $hadCursor } catch { }
  }
}

Write-Host ''
$catalogue = @(Get-Agents)
if (-not (@($catalogue | Where-Object { $_.Installed }).Count -gt 0)) {
  Write-Host 'None of the supported agents were detected, so all are listed.' -ForegroundColor Yellow
}
$agents = Select-Agents $catalogue
Write-Host ("Agents: " + $agents) -ForegroundColor Green

# Kokoro declares Requires-Python >=3.10,<3.13. An interpreter that is too NEW
# is rejected as firmly as one too old: on 3.13, pip falls back to building
# blis/thinc from source, which fails deep inside the install with an error
# that looks nothing like a version problem.
$PyMinEdge   = [version]'3.9'
$PyMinKokoro = [version]'3.10'
$PyMaxKokoro = [version]'3.12'

# Probe one interpreter invocation: returns its full path if its version is
# inside [min, max], else $null. Guards against the Windows Store stub, which
# sits on PATH and looks like an interpreter but is not one.
function Test-PyCandidate ($exe, $extraArgs, $min, $max) {
  try {
    # No quote characters inside the probe: PowerShell 5.1 strips embedded
    # double quotes from native-command arguments, and python then sees a
    # syntax error instead of a version.
    $out = & $exe @extraArgs -c 'import sys; v = sys.version_info; print(str(v[0]) + chr(46) + str(v[1])); print(sys.executable)' 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $lines = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($lines.Count -lt 2) { return $null }
    $v = [version]$lines[0]
    if ($v -lt $min) { return $null }
    if ($max -and $v -gt $max) { return $null }
    if (Test-Path $lines[1]) { return $lines[1] }
    return $null
  } catch { return $null }
}

# Sweep newest-allowed-first: the py launcher lets us ask for a specific minor
# version even when bare "python" resolves to one outside the window.
function Find-Python ($min, $max) {
  $tries = @(
    @{ Exe = 'py';      Args = @('-3.12') },
    @{ Exe = 'py';      Args = @('-3.11') },
    @{ Exe = 'py';      Args = @('-3.10') },
    @{ Exe = 'python';  Args = @() },
    @{ Exe = 'python3'; Args = @() },
    @{ Exe = 'py';      Args = @('-3') }
  )
  foreach ($t in $tries) {
    $p = Test-PyCandidate $t.Exe $t.Args $min $max
    if ($p) { return $p }
  }
  return $null
}

# The dependencies live in a private venv at ~/.agent-voice/venv, not in
# --user site-packages: --user is refused outright by Store and MSYS2 Pythons,
# and a shared site bleeds into and from project environments. python_cmd in
# the config points into the venv, so the hooks always find what was installed.
function Initialize-Venv ($basePython) {
  $vdir = Join-Path $target 'venv'
  $vpy  = Join-Path $vdir 'Scripts\python.exe'
  if (-not (Test-Path $vpy)) {
    Write-Host "Creating private environment at $vdir ..."
    & $basePython -m venv $vdir
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $vpy)) { return $null }
  }
  return $vpy
}

# Falling back to native is stated out loud rather than done quietly, so nobody
# ends up wondering why the voice sounds robotic. Names the accepted range: the
# instinct on a version error is to install the newest Python, which for Kokoro
# makes it worse.
function Deny-PythonEngine ($engineName, $rangeText) {
  Write-Host ''
  Write-Host "No usable Python for $engineName was found. It needs $rangeText." -ForegroundColor Yellow
  Write-Host '  Install one from https://www.python.org/downloads/ and tick "Add python.exe to PATH",' -ForegroundColor Yellow
  Write-Host '  then run this installer again and pick that engine.' -ForegroundColor Yellow
  Write-Host "  Note: a NEWER Python does not help; the range really is $rangeText." -ForegroundColor Yellow
  Write-Host 'Using Native offline for now, so you still get a working voice.' -ForegroundColor Green
}

# Kokoro's voices come from lib/kokoro-voices.json, the same file the hooks read for
# "voice list" and for validating "voice model", so the ids and the published quality
# grades cannot drift between what you can install and what you can switch to.
$KOKORO_VOICES = @(Get-Content (Join-Path $src 'lib\kokoro-voices.json') -Raw | ConvertFrom-Json)
# The voice picker (arrow keys, P to preview) lives in core/windows/pick-voice.ps1
# so that the installer and the in-session "voice pick" command share one
# implementation rather than drifting apart.
. (Join-Path $src 'core\windows\pick-voice.ps1')
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
    # Free the BSTR after copying it out, so the plaintext key does not linger
    # at a known process-memory address (R-12).
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try     { $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $keyFile = Join-Path $target 'elevenlabs-key'
    Set-Content -Path $keyFile -Value $key -NoNewline
    # Owner-only ACL, matching the chmod 600 the macOS installer does.
    icacls $keyFile /inheritance:r /grant:r "*${me}:F" | Out-Null
    $vid = Read-Host 'Voice ID (Enter for default British male "George")'
    if ([string]::IsNullOrWhiteSpace($vid)) { $vid = 'JBFqnCBsd6RMkjVDRZzb' }
    $cfg += 'engine=elevenlabs'; $cfg += "eleven_voice=$vid"; $cfg += 'eleven_model=eleven_flash_v2_5'
    Write-Host 'ElevenLabs selected. Key stored locally (not in any script).' -ForegroundColor Green
  }
  '3' {
    $base = Find-Python $PyMinKokoro $PyMaxKokoro
    if (-not $base) { Deny-PythonEngine 'Kokoro' 'Python 3.10 to 3.12'; $cfg += 'engine=native'; break }
    $vpy = Initialize-Venv $base
    if (-not $vpy) {
      Write-Host "Could not create the private environment (using $base). Falling back to Native offline." -ForegroundColor Yellow
      $cfg += 'engine=native'; break
    }
    Write-Host 'Kokoro offline selected. Nothing will leave this machine.' -ForegroundColor Green
    Write-Host 'Kokoro keeps a warm background process so replies start speaking in ~1.7s.' -ForegroundColor Gray
    Write-Host 'It uses about 1.7GB of RAM while resident, and exits after 15 idle minutes.' -ForegroundColor Gray

    # Dependencies and the model come first, so that voice previews are quick when
    # you get to the list rather than costing ten seconds each.
    # espeak-ng is not required: the espeakng-loader dependency bundles it.
    $have = $false
    try { & $vpy -c 'import kokoro, soundfile' *> $null; if ($LASTEXITCODE -eq 0) { $have = $true } } catch {}
    if (-not $have) {
      Write-Host 'Installing Kokoro into the private environment ... this pulls in PyTorch and takes a few minutes.'
      & $vpy -m pip install kokoro soundfile
      if ($LASTEXITCODE -ne 0) {
        Write-Host 'The Kokoro install FAILED (see pip output above). Falling back to Native offline;' -ForegroundColor Red
        Write-Host "re-run this installer after fixing it. Environment: $vpy" -ForegroundColor Red
        $cfg += 'engine=native'; break
      }
    }

    # Warm up: pre-download the weights and the spaCy model that Kokoro's text
    # front-end fetches on first use, so the first spoken reply is not silent.
    Write-Host 'Downloading Kokoro voice weights (~300MB) and language model (one time) ...'
    $probe = Join-Path $state 'warmup.wav'
    'agent voice is ready' | & $vpy (Join-Path $target 'kokoro-tts.py') $probe 'bf_emma' 1.15
    $kokoroWorks = (Test-Path $probe) -and ((Get-Item $probe).Length -gt 500)
    Remove-Item $probe -Force -ErrorAction SilentlyContinue

    if ($kokoroWorks) {
      Write-Host 'Kokoro is working.' -ForegroundColor Green
      Write-Host ''
      $kv = Select-Voice $KOKORO_VOICES $target $state 'bf_emma' $vpy
    } else {
      Write-Host 'Kokoro could not synthesise yet. Voice will use the basic Windows one until this is fixed;' -ForegroundColor Yellow
      Write-Host "run  $vpy -m pip install kokoro soundfile  by hand to see the error." -ForegroundColor Yellow
      $kv = 'bf_emma'
    }

    $cfg += 'engine=kokoro'; $cfg += "kokoro_voice=$kv"; $cfg += 'kokoro_speed=1.15'
    $cfg += "python_cmd=$vpy"
    Write-Host ("Voice: " + $kv) -ForegroundColor Green
  }
  '4' {
    $cfg += 'engine=native'
    Write-Host 'Native offline selected.' -ForegroundColor Green
  }
  default {
    $base = Find-Python $PyMinEdge $null
    if (-not $base) { Deny-PythonEngine 'edge-tts' 'Python 3.9 or newer'; $cfg += 'engine=native'; break }
    $vpy = Initialize-Venv $base
    if (-not $vpy) {
      Write-Host "Could not create the private environment (using $base). Falling back to Native offline." -ForegroundColor Yellow
      $cfg += 'engine=native'; break
    }
    $cfg += 'engine=edge'; $cfg += 'edge_voice=en-US-AvaNeural'; $cfg += 'edge_rate=+15%'
    $cfg += "python_cmd=$vpy"
    Write-Host 'edge-tts (Ava) selected.' -ForegroundColor Green
    $have = $false
    try { & $vpy -m edge_tts --version *> $null; if ($LASTEXITCODE -eq 0) { $have = $true } } catch {}
    if (-not $have) {
      Write-Host 'Installing edge-tts into the private environment ...'
      & $vpy -m pip install edge-tts
      if ($LASTEXITCODE -ne 0) { Write-Host 'The edge-tts install FAILED (see pip output above).' -ForegroundColor Red }
    }
    # Confirm it can actually speak, rather than assuming pip succeeded.
    try { & $vpy -m edge_tts --version *> $null } catch {}
    if ($LASTEXITCODE -ne 0) {
      Write-Host 'edge-tts still is not working, so replies will use the basic Windows voice.' -ForegroundColor Yellow
      Write-Host "Run  $vpy -m pip install edge-tts  by hand to see the error." -ForegroundColor Yellow
    }
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
Write-Host 'Also per session:  voice engine  |  voice model  |  voice speed  |  voice list'
Write-Host 'Forgotten one? Type:  voice help'
Write-Host 'Stop speech anytime:   Ctrl+Alt+S'
