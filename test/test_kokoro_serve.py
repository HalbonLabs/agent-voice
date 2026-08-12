"""Unit tests for the pure parts of core/kokoro_serve.py.

Run directly (python test/test_kokoro_serve.py) or via the Node suite, which
spawns this file and skips cleanly when no Python is installed. Imports only
the stdlib: kokoro_serve defers the kokoro import until main(), so importing
the module for testing needs no ML dependencies.
"""

import os
import socket
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "core"))
import kokoro_serve  # noqa: E402


class SafeOutputPath(unittest.TestCase):
    def setUp(self):
        self.state = Path(tempfile.mkdtemp(prefix="av-state-"))

    def test_accepts_a_legitimate_state_dir_path(self):
        raw = str(self.state / "say.abc123.wav")
        self.assertEqual(kokoro_serve.safe_output_path(self.state, raw), Path(raw))

    def test_rejects_relative_path(self):
        self.assertIsNone(kokoro_serve.safe_output_path(self.state, "say.x.wav"))

    def test_rejects_empty_path(self):
        self.assertIsNone(kokoro_serve.safe_output_path(self.state, ""))

    def test_rejects_parent_traversal(self):
        raw = str(self.state / ".." / "escape.wav")
        self.assertIsNone(kokoro_serve.safe_output_path(self.state, raw))

    def test_rejects_other_absolute_directory(self):
        other = Path(tempfile.mkdtemp(prefix="av-other-"))
        self.assertIsNone(kokoro_serve.safe_output_path(self.state, str(other / "say.x.wav")))

    def test_rejects_control_filenames(self):
        # A token holder must not be able to overwrite the daemon's own state.
        for name in ("kokoro.port", "kokoro.lock", "voice-on", "on.abc", "say.wav", "say..wav.exe"):
            self.assertIsNone(
                kokoro_serve.safe_output_path(self.state, str(self.state / name)),
                f"{name} must be rejected",
            )

    def test_accepts_preview_and_warmup(self):
        # pick-voice writes preview.wav, the installers probe with warmup.wav.
        for name in ("preview.wav", "warmup.wav"):
            raw = str(self.state / name)
            self.assertEqual(kokoro_serve.safe_output_path(self.state, raw), Path(raw))

    def test_rejects_symlink_escape(self):
        outside = Path(tempfile.mkdtemp(prefix="av-outside-"))
        link = self.state / "link"
        try:
            link.symlink_to(outside, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks not available (Windows without developer mode)")
        raw = str(link / "say.x.wav")
        self.assertIsNone(kokoro_serve.safe_output_path(self.state, raw))


class PortFile(unittest.TestCase):
    def test_read_port_file_roundtrip(self):
        state = Path(tempfile.mkdtemp(prefix="av-state-"))
        (state / "kokoro.port").write_text("54321 deadbeef", encoding="utf-8")
        self.assertEqual(kokoro_serve.read_port_file(state), (54321, "deadbeef"))

    def test_write_port_file_roundtrip_and_no_temp_left(self):
        state = Path(tempfile.mkdtemp(prefix="av-state-"))
        port_file = state / "kokoro.port"
        kokoro_serve.write_port_file(port_file, 54321, "deadbeef")
        self.assertEqual(kokoro_serve.read_port_file(state), (54321, "deadbeef"))
        self.assertFalse(port_file.with_suffix(".port.tmp").exists())

    @unittest.skipIf(sys.platform == "win32", "POSIX mode bits are meaningless on Windows")
    def test_port_file_is_owner_only(self):
        import stat

        state = Path(tempfile.mkdtemp(prefix="av-state-"))
        port_file = state / "kokoro.port"
        kokoro_serve.write_port_file(port_file, 54321, "deadbeef")
        self.assertEqual(stat.S_IMODE(port_file.stat().st_mode), 0o600)

    def test_read_port_file_missing_or_garbled(self):
        state = Path(tempfile.mkdtemp(prefix="av-state-"))
        self.assertIsNone(kokoro_serve.read_port_file(state))
        (state / "kokoro.port").write_text("not a port line at all", encoding="utf-8")
        self.assertIsNone(kokoro_serve.read_port_file(state))


class TakeLock(unittest.TestCase):
    def setUp(self):
        self.state = Path(tempfile.mkdtemp(prefix="av-state-"))
        self.lock = self.state / "kokoro.lock"

    def test_free_lock_is_taken(self):
        self.assertTrue(kokoro_serve.take_lock(self.state))
        self.assertEqual(self.lock.read_text(encoding="ascii"), str(os.getpid()))

    def test_live_holder_wins(self):
        # Our own PID is certainly alive.
        self.lock.write_text(str(os.getpid()), encoding="ascii")
        self.assertFalse(kokoro_serve.take_lock(self.state))

    def test_dead_holder_is_taken_over_immediately(self):
        # R-19: no 180 s grace; a gone holder means takeover on the spot.
        self.lock.write_text("999999999", encoding="ascii")
        self.assertTrue(kokoro_serve.take_lock(self.state))
        self.assertEqual(self.lock.read_text(encoding="ascii"), str(os.getpid()))

    def test_garbage_lock_is_taken_over(self):
        self.lock.write_text("not a pid", encoding="ascii")
        self.assertTrue(kokoro_serve.take_lock(self.state))

    def test_pid_alive(self):
        self.assertTrue(kokoro_serve.pid_alive(os.getpid()))
        self.assertFalse(kokoro_serve.pid_alive(999999999))
        self.assertFalse(kokoro_serve.pid_alive(0))
        self.assertFalse(kokoro_serve.pid_alive(-1))


class FakeEngine:
    DEFAULT_VOICE = "fake"
    DEFAULT_SPEED = 1.0

    def synth_to_wav(self, text, out, voice=None, speed=None):
        Path(out).write_bytes(b"RIFF-fake-wav")


class Serve(unittest.TestCase):
    """Drives serve() over a real loopback socket with a fake engine."""

    def setUp(self):
        self.state = Path(tempfile.mkdtemp(prefix="av-state-"))
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.token = "test-token"
        self.thread = threading.Thread(
            target=kokoro_serve.serve,
            args=(self.state, self.sock, self.token, FakeEngine()),
            daemon=True,
        )
        self.thread.start()

    def tearDown(self):
        try:
            kokoro_serve.request(self.port, self.token, {"cmd": "quit"}, timeout=2)
        except Exception:
            pass
        self.thread.join(timeout=5)
        self.sock.close()

    def ask(self, payload):
        return kokoro_serve.request(self.port, self.token, payload, timeout=5)

    def test_ping(self):
        self.assertTrue(self.ask({"cmd": "ping"}).get("ok"))

    def test_bad_token(self):
        reply = kokoro_serve.request(self.port, "wrong", {"cmd": "ping"}, timeout=5)
        self.assertFalse(reply.get("ok"))
        self.assertEqual(reply.get("error"), "bad token")

    def test_synth_writes_allowed_file(self):
        out = self.state / "say.test.wav"
        reply = self.ask({"cmd": "synth", "text": "hello", "out": str(out)})
        self.assertTrue(reply.get("ok"), reply)
        self.assertTrue(out.exists())

    def test_synth_refuses_control_file(self):
        out = self.state / "kokoro.port"
        reply = self.ask({"cmd": "synth", "text": "hello", "out": str(out)})
        self.assertFalse(reply.get("ok"))
        self.assertEqual(reply.get("error"), "output path not permitted")
        self.assertFalse(out.exists())

    def test_synth_refuses_oversized_request_body(self):
        # 100 KB overflows MAX_REQUEST; the server drops the connection without
        # synthesising. The client may see a reset mid-send, an empty reply, or
        # an error: all are rejections. The property that matters is no file.
        out = self.state / "say.test.wav"
        try:
            reply = self.ask({"cmd": "synth", "text": "x" * (100 * 1024), "out": str(out)})
            self.assertFalse(reply.get("ok"))
        except OSError:
            pass
        self.assertFalse(out.exists())

    def test_synth_refuses_oversized_text(self):
        # Fits in MAX_REQUEST but exceeds MAX_TEXT: must hit the explicit limit.
        out = self.state / "say.test.wav"
        reply = self.ask({"cmd": "synth", "text": "y" * (9 * 1024), "out": str(out)})
        self.assertFalse(reply.get("ok"))
        self.assertEqual(reply.get("error"), "text too long")
        self.assertFalse(out.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
