#!/usr/bin/env python3
"""agent-voice Kokoro synthesiser (shared by the Windows and macOS hooks).

Reads the summary text on stdin, writes a 24 kHz WAV to argv[1]. Playback is the
caller's job. Any failure exits non-zero and prints to stderr, so the calling hook
falls back to the native offline voice rather than going silent.

Usage:  echo "text" | python kokoro-tts.py OUT.wav [voice] [speed]

Two paths, in order:

1. Ask the warm daemon (kokoro_serve.py). Costs ~1.6s, because the model is
   already loaded. This is the normal case.
2. No daemon yet: synthesise in-process (~10s, since importing PyTorch and
   building the pipeline dominate), then start the daemon so the next reply
   takes the fast path.

Kokoro is hexgrad/Kokoro-82M, Apache-2.0 open weights, run entirely on this
machine. Weights are cached by Hugging Face on first use (~300 MB).
"""

import subprocess
import sys
from pathlib import Path

DEFAULT_VOICE = "bf_emma"
DEFAULT_SPEED = 1.15


def try_daemon(state, text, out, voice, speed):
    """Synthesise via the warm daemon. False if it is absent or unhappy."""
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        # Cheap import: kokoro_serve's module body is stdlib-only, so this does
        # not drag in PyTorch. Shared so the wire protocol lives in one place.
        import kokoro_serve as serve

        found = serve.read_port_file(state)
        if not found:
            return False
        port, token = found
        reply = serve.request(
            port, token,
            {"cmd": "synth", "text": text, "out": str(out), "voice": voice, "speed": speed},
            timeout=120,
        )
        return bool(reply.get("ok"))
    except Exception:
        return False


def spawn_daemon(state, voice):
    """Start the daemon detached, so it outlives this hook process. The daemon
    guards against duplicates itself, so calling this spuriously is harmless."""
    script = Path(__file__).resolve().with_name("kokoro_serve.py")
    if not script.exists():
        return
    kwargs = {}
    if sys.platform == "win32":
        DETACHED_PROCESS = 0x00000008
        CREATE_NO_WINDOW = 0x08000000
        kwargs["creationflags"] = DETACHED_PROCESS | CREATE_NO_WINDOW
    else:
        kwargs["start_new_session"] = True
    try:
        subprocess.Popen(
            [sys.executable, str(script), str(state), voice],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            **kwargs,
        )
    except Exception:
        pass


def main() -> int:
    if len(sys.argv) < 2:
        print("agent-voice: no output path given", file=sys.stderr)
        return 2

    out = sys.argv[1]
    voice = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else DEFAULT_VOICE
    try:
        speed = float(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else DEFAULT_SPEED
    except ValueError:
        speed = DEFAULT_SPEED

    # Decode explicitly: the hooks pipe UTF-8 regardless of the console codepage.
    # utf-8-sig, not utf-8: PowerShell prefixes piped input with a BOM, and U+FEFF
    # is not whitespace to str.strip(), so plain utf-8 would leave a "non-empty"
    # BOM-only string and feed a stray character to the synthesiser.
    text = sys.stdin.buffer.read().decode("utf-8-sig", "replace").strip()
    if not text:
        print("agent-voice: empty text on stdin", file=sys.stderr)
        return 3

    # The hooks always write into the state dir, which is where the daemon keeps
    # its port file and the only place it will write.
    state = Path(out).resolve().parent

    if try_daemon(state, text, out, voice, speed):
        return 0

    # Cold path: no daemon. Synthesise here, then warm one up for next time.
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import kokoro_engine as engine
    except ImportError as exc:
        print(f"agent-voice: missing dependency ({exc}). pip install kokoro soundfile", file=sys.stderr)
        return 4

    try:
        engine.synth_to_wav(text, out, voice=voice, speed=speed)
    except Exception as exc:                            # noqa: BLE001
        print(f"agent-voice: kokoro synthesis failed: {exc}", file=sys.stderr)
        return 5

    spawn_daemon(state, voice)
    return 0


if __name__ == "__main__":
    sys.exit(main())
