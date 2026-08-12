#!/usr/bin/env python3
"""agent-voice Kokoro daemon: loads the model once, then synthesises on request.

Why this exists: a fresh process pays ~8.6s to import PyTorch and build the
pipeline, but only ~1.6s to actually synthesise. Since the Stop hook runs a new
process every reply, that startup was being paid every single time. Keeping one
warm process resident moves the cost to once per session.

Usage:  python kokoro_serve.py STATE_DIR [voice]

Listens on 127.0.0.1 with an OS-assigned port, and writes "<port> <token>" to
STATE_DIR/kokoro.port only once the model is loaded, so the port file appearing
means "ready to serve". Requests and replies are one JSON line each. Exits after
IDLE_TIMEOUT seconds with no work, so it never lingers holding ~1 GB forever.

Not a network service: it binds loopback only, and a token plus a path check
mean a request must come from something that can already read this user's files.
"""

import json
import os
import re
import secrets
import socket
import sys
import time
from pathlib import Path

IDLE_TIMEOUT = 900     # 15 minutes with no requests, then exit
STARTUP_GRACE = 180    # a lock younger than this means another daemon is loading
MAX_REQUEST = 64 * 1024
MAX_TEXT = 8 * 1024    # far beyond any spoken summary; bounds CPU on the single-threaded loop

# The only filenames a client may write: per-session summaries, the voice-picker
# preview, and the installer's warmup probe. Everything else in the state dir is
# control state (kokoro.port, kokoro.lock, voice flags) that WAV bytes must
# never be able to overwrite.
_OUT_NAME = re.compile(r"^(say\.[A-Za-z0-9_.-]{1,128}|preview|warmup)\.wav$")


def read_port_file(state):
    """Return (port, token) from the port file, or None."""
    try:
        port, token = (state / "kokoro.port").read_text(encoding="utf-8").split()
        return int(port), token
    except Exception:
        return None


def request(port, token, payload, timeout=5):
    """Send one JSON request to a running daemon and return its reply dict."""
    payload = dict(payload, token=token)
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode("utf-8", "replace").strip() or "{}")


def daemon_alive(state):
    """True if a daemon is already serving on the recorded port."""
    found = read_port_file(state)
    if not found:
        return False
    try:
        return bool(request(found[0], found[1], {"cmd": "ping"}, timeout=2).get("ok"))
    except Exception:
        return False


def take_lock(state):
    """Single-daemon guard. True if we may proceed to load the model."""
    lock = state / "kokoro.lock"
    for _ in range(2):
        try:
            fd = os.open(str(lock), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode("ascii"))
            os.close(fd)
            return True
        except FileExistsError:
            try:
                age = time.time() - lock.stat().st_mtime
            except OSError:
                continue          # vanished under us, try again
            if age < STARTUP_GRACE:
                return False      # another daemon is starting up; let it win
            try:
                lock.unlink()     # stale lock from a crashed daemon; take over
            except OSError:
                return False
    return False


def write_port_file(port_file, port, token):
    """Publish "<port> <token>" atomically and owner-readable only. The token
    is the only thing keeping other local users off the daemon, so the file is
    created 0600 from the start: a chmod after write would leave a window where
    it exists world-readable under the default umask."""
    tmp = port_file.with_suffix(".port.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(f"{port} {token}")
    os.replace(tmp, port_file)  # atomic: readers never see a partial file


def safe_output_path(state, raw):
    """Only allow writes directly inside the state dir, under an allowlisted
    synthesis filename, so a request cannot aim the synthesiser at an
    arbitrary file or at the daemon's own control files."""
    path = Path(raw)
    if not path.is_absolute():
        return None
    if not _OUT_NAME.match(path.name):
        return None
    try:
        if path.resolve().parent != state.resolve():
            return None
    except OSError:
        return None
    return path


def serve(state, sock, token, engine):
    deadline = time.time() + IDLE_TIMEOUT
    while True:
        sock.settimeout(max(1.0, deadline - time.time()))
        try:
            conn, _ = sock.accept()
        except socket.timeout:
            return
        with conn:
            conn.settimeout(10)
            try:
                buf = b""
                while b"\n" not in buf and len(buf) < MAX_REQUEST:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    buf += chunk
                if len(buf) >= MAX_REQUEST:
                    continue          # oversized request body; drop before parsing
                req = json.loads(buf.decode("utf-8", "replace").strip() or "{}")
            except Exception:
                continue

            reply = {"ok": False, "error": "bad request"}
            if not secrets.compare_digest(str(req.get("token", "")), token):
                reply = {"ok": False, "error": "bad token"}
            elif req.get("cmd") == "ping":
                reply = {"ok": True}
            elif req.get("cmd") == "quit":
                try:
                    conn.sendall((json.dumps({"ok": True}) + "\n").encode("utf-8"))
                except Exception:
                    pass
                return
            elif req.get("cmd") == "synth":
                out = safe_output_path(state, req.get("out", ""))
                text = (req.get("text") or "").strip()
                if out is None:
                    reply = {"ok": False, "error": "output path not permitted"}
                elif not text:
                    reply = {"ok": False, "error": "empty text"}
                elif len(text) > MAX_TEXT:
                    reply = {"ok": False, "error": "text too long"}
                else:
                    try:
                        engine.synth_to_wav(
                            text,
                            str(out),
                            voice=req.get("voice") or engine.DEFAULT_VOICE,
                            speed=float(req.get("speed") or engine.DEFAULT_SPEED),
                        )
                        reply = {"ok": True}
                        deadline = time.time() + IDLE_TIMEOUT
                    except Exception as exc:            # noqa: BLE001
                        reply = {"ok": False, "error": str(exc)}
            try:
                conn.sendall((json.dumps(reply) + "\n").encode("utf-8"))
            except Exception:
                pass


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: kokoro_serve.py STATE_DIR [voice] [--quit]", file=sys.stderr)
        return 2
    state = Path(sys.argv[1])
    if not state.is_dir():
        print(f"agent-voice: no such state dir: {state}", file=sys.stderr)
        return 2
    args = sys.argv[2:]

    # --quit: ask a resident daemon to exit now, freeing its ~1.7 GB rather than
    # waiting out the idle timeout. Used by the uninstaller.
    if "--quit" in args:
        found = read_port_file(state)
        if found:
            try:
                request(found[0], found[1], {"cmd": "quit"}, timeout=5)
            except Exception:
                pass
        return 0

    voice = args[0] if args and not args[0].startswith("-") else None

    if daemon_alive(state):
        return 0
    if not take_lock(state):
        return 0

    lock = state / "kokoro.lock"
    port_file = state / "kokoro.port"
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import kokoro_engine as engine

        # Load the model before advertising the port, so any successful connect
        # means the daemon is ready to synthesise immediately.
        engine.get_pipeline(engine.lang_for(voice or engine.DEFAULT_VOICE))

        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.bind(("127.0.0.1", 0))
        sock.listen(8)
        token = secrets.token_hex(16)

        write_port_file(port_file, sock.getsockname()[1], token)

        with sock:
            serve(state, sock, token, engine)
        return 0
    except Exception as exc:                            # noqa: BLE001
        print(f"agent-voice: kokoro daemon failed: {exc}", file=sys.stderr)
        return 1
    finally:
        for path in (port_file, lock):
            try:
                path.unlink()
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
