"""Unit tests for the pure parts of core/kokoro_serve.py.

Run directly (python test/test_kokoro_serve.py) or via the Node suite, which
spawns this file and skips cleanly when no Python is installed. Imports only
the stdlib: kokoro_serve defers the kokoro import until main(), so importing
the module for testing needs no ML dependencies.
"""

import sys
import tempfile
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
