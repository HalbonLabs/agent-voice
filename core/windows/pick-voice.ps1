# Shared Kokoro voice picker: arrow keys to move, P to hear the highlighted voice,
# Enter to choose. Used two ways, so that the installer and the in-session
# "voice pick" command cannot drift apart:
#
#   1. Dot-sourced by install.ps1, which calls Select-Voice directly.
#   2. Run as a script by the voice-context hook, with -SessionId, in its own
#      console window. The hook itself cannot do this: it runs non-interactively
#      with stdin carrying the JSON payload, so it has no keyboard to read.
#
# Run:  pick-voice.ps1 -SessionId <id> -Engine kokoro

param(
  [string]$SessionId = '',
  [string]$Engine    = 'kokoro',
  [string]$Preview   = '',      # play one voice and exit; used by "voice preview"
  [string]$Root      = (Join-Path $env:USERPROFILE '.agent-voice')
)

# Config, needed by both modes below for the interpreter and the default voice.
$pickCfg = @{}
$pickCfgFile = Join-Path $Root 'config'
if (Test-Path $pickCfgFile) {
  Get-Content $pickCfgFile | ForEach-Object {
    if ($_ -match '^\s*([^#=]+?)\s*=\s*(.*)$') { $pickCfg[$matches[1].Trim()] = $matches[2].Trim() }
  }
}
$pickPy = if ($pickCfg.python_cmd) { $pickCfg.python_cmd } elseif ($pickCfg.kokoro_python) { $pickCfg.kokoro_python } else { 'python' }
# Speak a sample in one voice. Cheap once the daemon is warm, which is why voice
# selection now happens after the model has been pre-loaded.
function Invoke-VoicePreview ($target, $state, $voice, $pyExe = 'python') {
  $wav = Join-Path $state 'preview.wav'
  Remove-Item $wav -Force -ErrorAction SilentlyContinue
  $prev = $OutputEncoding
  $OutputEncoding = New-Object Text.UTF8Encoding $false
  'This is how I will read your summaries back to you.' | & $pyExe (Join-Path $target 'kokoro-tts.py') $wav $voice 1.15 2>$null
  $OutputEncoding = $prev
  if ((Test-Path $wav) -and ((Get-Item $wav).Length -gt 500)) {
    try { $p = New-Object System.Media.SoundPlayer $wav; $p.PlaySync(); $p.Dispose() } catch { }
    Remove-Item $wav -Force -ErrorAction SilentlyContinue
    return $true
  }
  return $false
}

# Single-select list with a scrolling viewport and audio preview.
function Select-Voice ($voices, $target, $state, $default, $pyExe = 'python') {
  if ([Console]::IsInputRedirected) {
    $typed = Read-Host "Kokoro voice (Enter for British female `"$default`")"
    if ([string]::IsNullOrWhiteSpace($typed)) { return $default }
    return $typed.Trim()
  }

  $pos = [Math]::Max(0, [array]::IndexOf(($voices | ForEach-Object { $_.id }), $default))
  $view = [Math]::Min(12, $voices.Count)
  $rows = $view + 2                      # list lines, a scroll hint, and a status line
  $start = 0
  $width = [Math]::Max(40, [Console]::WindowWidth - 1)
  $status = 'Press P to hear the highlighted voice.'
  $pending = $false
  $firstDraw = $true
  $hadCursor = $true
  try { $hadCursor = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { }

  try {
    while ($true) {
      if ($pos -lt $start) { $start = $pos }
      if ($pos -ge $start + $view) { $start = $pos - $view + 1 }

      if ($firstDraw) { $firstDraw = $false }
      else { [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - $rows)) }

      for ($i = $start; $i -lt $start + $view; $i++) {
        $v = $voices[$i]
        $cur = if ($i -eq $pos) { '>' } else { ' ' }
        $line = "{0} {1,-14} {2,-11} {3,-7} grade {4}" -f $cur, $v.id, $v.lang, $v.sex, $v.grade
        if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
        $colour = if ($i -eq $pos) { 'Cyan' } else { 'Gray' }
        Write-Host ($line.PadRight($width)) -ForegroundColor $colour
      }
      $hint = "  showing {0}-{1} of {2}   Up/Down to move, P to preview, Enter to choose" -f ($start + 1), ($start + $view), $voices.Count
      if ($hint.Length -gt $width) { $hint = $hint.Substring(0, $width) }
      Write-Host ($hint.PadRight($width)) -ForegroundColor DarkGray
      if ($status.Length -gt $width) { $status = $status.Substring(0, $width) }
      Write-Host ("  " + $status).PadRight($width) -ForegroundColor DarkGray

      if ($pending) {
        $pending = $false
        $ok = Invoke-VoicePreview $target $state $voices[$pos].id $pyExe
        $status = if ($ok) { "Played $($voices[$pos].id). Press P again, or Enter to choose it." }
                  else { "Could not synthesise $($voices[$pos].id). Try another." }
        continue
      }

      $key = [Console]::ReadKey($true)
      switch ($key.Key) {
        'UpArrow'   { $pos = ($pos - 1 + $voices.Count) % $voices.Count }
        'DownArrow' { $pos = ($pos + 1) % $voices.Count }
        'PageUp'    { $pos = [Math]::Max(0, $pos - $view) }
        'PageDown'  { $pos = [Math]::Min($voices.Count - 1, $pos + $view) }
        'Home'      { $pos = 0 }
        'End'       { $pos = $voices.Count - 1 }
        'Enter'     { Write-Host ''; return $voices[$pos].id }
        default {
          if ($key.KeyChar -eq 'p' -or $key.KeyChar -eq 'P') {
            $status = "Synthesising $($voices[$pos].id) ..."
            $pending = $true
          }
        }
      }
    }
  } finally {
    try { [Console]::CursorVisible = $hadCursor } catch { }
  }
}

# --- preview mode: play one voice, no window, no UI ---
if ($Preview) {
  Invoke-VoicePreview $Root (Join-Path $Root 'state') $Preview $pickPy | Out-Null
  exit 0
}

# --- script mode: called by the hook, writes the session's voice and exits ---
if ($SessionId) {
  $state = Join-Path $Root 'state'
  $cfg   = $pickCfg
  $pyExe = $pickPy

  if ($Engine -ne 'kokoro') {
    Write-Host "The voice picker only covers Kokoro, since it is the only engine whose voices can be auditioned offline." -ForegroundColor Yellow
    Write-Host "You are on '$Engine'. Switch with 'voice engine kokoro' first, or use 'voice model' to see that engine's list."
    Start-Sleep -Seconds 6
    exit 0
  }

  $voicesFile = Join-Path $Root 'lib\kokoro-voices.json'
  if (-not (Test-Path $voicesFile)) { Write-Host 'Voice catalogue not found.' -ForegroundColor Red; Start-Sleep -Seconds 5; exit 1 }
  $voices = @(Get-Content $voicesFile -Raw | ConvertFrom-Json)

  $flag = Join-Path $state "voice.$Engine.$SessionId"
  $current = if (Test-Path $flag) { (Get-Content $flag -Raw).Trim() }
             elseif ($cfg.kokoro_voice) { $cfg.kokoro_voice } else { 'bf_emma' }

  Write-Host ''
  Write-Host 'agent-voice: pick a voice for this session' -ForegroundColor Cyan
  Write-Host '-------------------------------------------'
  Write-Host ''
  $chosen = Select-Voice $voices $Root $state $current $pyExe
  Set-Content -Path $flag -Value $chosen -NoNewline

  Write-Host ''
  Write-Host "Voice set to $chosen for this session." -ForegroundColor Green
  Write-Host 'You can close this window; your next reply will use it.'
  Start-Sleep -Seconds 3
}