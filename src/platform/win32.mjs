// Windows platform layer: play a file, speak via SAPI, identify and stop
// processes. Playback and SAPI go through short PowerShell children; that costs
// PowerShell startup, but only inside the detached speaker, which no agent
// waits for. Everything engine-shaped lives above this in src/engines.
import { execFileSync, spawnSync } from 'child_process';

function psRun(script) {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { stdio: 'ignore' });
  return r.status === 0;
}

// MCI for MP3 (returns success only if playback actually happened; MCI fails
// silently otherwise, notably rc=304 when the path exceeds ~128 chars).
// SoundPlayer for WAV: native, blocking, no path-length limits.
export function play(file) {
  const esc = file.replace(/'/g, "''");
  if (/\.mp3$/i.test(file)) {
    return psRun(`
      Add-Type -Name Mci -Namespace Native -MemberDefinition '[DllImport("winmm.dll", CharSet = CharSet.Auto)] public static extern int mciSendString(string cmd, System.Text.StringBuilder ret, int len, System.IntPtr hwnd);'
      if ([Native.Mci]::mciSendString('open "' + '${esc}' + '" type mpegvideo alias avq', $null, 0, [IntPtr]::Zero) -ne 0) { exit 1 }
      $rc = [Native.Mci]::mciSendString('play avq wait', $null, 0, [IntPtr]::Zero)
      [Native.Mci]::mciSendString('close avq', $null, 0, [IntPtr]::Zero) | Out-Null
      if ($rc -ne 0) { exit 1 } else { exit 0 }`);
  }
  return psRun(`
    try {
      $p = New-Object System.Media.SoundPlayer '${esc}'
      $p.PlaySync(); $p.Dispose(); exit 0
    } catch { exit 1 }`);
}

// SAPI's scale is -10..10 with 0 normal, so 1.2x lands on its long-standing
// default of 2.
export function speakNative(text, { speed } = {}) {
  const rate = speed && isFinite(Number(speed))
    ? Math.max(-10, Math.min(10, Math.round((Number(speed) - 1) * 10)))
    : 2;
  const esc = String(text).replace(/'/g, "''");
  return psRun(`
    Add-Type -AssemblyName System.Speech
    $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $s.Rate = ${rate}
    $s.Speak('${esc}')
    $s.Dispose()`);
}

// The command line a PID is running, or '' if it is gone. A PID alone is never
// proof of identity (R-04).
export function pidCommand(pid) {
  try {
    const out = execFileSync('powershell.exe',
      ['-NoProfile', '-NonInteractive', '-Command',
       `(Get-CimInstance Win32_Process -Filter "ProcessId=${Number(pid)}").CommandLine`],
      { encoding: 'utf8' });
    return out.trim();
  } catch {
    return '';
  }
}

// taskkill /T takes the whole tree, so the PowerShell playing audio dies with
// the speaker it belongs to.
export function killTree(pid) {
  spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
}
