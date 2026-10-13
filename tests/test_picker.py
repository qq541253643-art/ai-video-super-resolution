from pathlib import Path
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from ai_video_restore import server
from ai_video_restore.media import MediaError


class PickerTests(unittest.TestCase):
    def setUp(self):
        mock = patch.object(server, "os", SimpleNamespace(name="nt"))
        mock.start()
        self.addCleanup(mock.stop)

    def test_unicode_multiselect_and_dedicated_sta_script(self):
        paths = [r"C:\视频\片段 1.mp4", r"C:\视频\测试二.mp4"]
        result = subprocess.CompletedProcess([], 0, "\r\n".join(paths) + "\r\n", "")
        with patch.object(server.subprocess, "run", return_value=result) as run:
            self.assertEqual(server._pick_files(), paths)
        args = run.call_args.args[0]
        self.assertIn("-STA", args)
        self.assertEqual(args[-2], "-File")
        self.assertTrue(Path(args[-1]).is_file())
        self.assertEqual(run.call_args.kwargs["encoding"], "utf-8")

    def test_cancel_returns_no_files(self):
        with patch.object(server.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")):
            self.assertEqual(server._pick_files(), [])

    def test_second_picker_is_rejected(self):
        server.PICKER_LOCK.acquire()
        try:
            with patch.object(server.subprocess, "run") as run:
                with self.assertRaisesRegex(MediaError, "已打开"):
                    server._pick_files()
                run.assert_not_called()
        finally:
            server.PICKER_LOCK.release()

    def test_failures_release_lock(self):
        for error in (subprocess.TimeoutExpired("picker", 600), OSError("cannot start")):
            with self.subTest(error=error), patch.object(server.subprocess, "run", side_effect=error):
                with self.assertRaises(MediaError):
                    server._pick_files()
                self.assertFalse(server.PICKER_LOCK.locked())

    def test_child_error_is_preserved(self):
        with patch.object(server.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "picker error")):
            with self.assertRaisesRegex(MediaError, "picker error"):
                server._pick_files()
        self.assertFalse(server.PICKER_LOCK.locked())


if __name__ == "__main__":
    unittest.main()
