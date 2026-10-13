import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == "nt", "requires Windows pythonw.exe")
class BackgroundTests(unittest.TestCase):
    def test_pythonw_serves_without_console_and_logs_errors(self):
        with tempfile.TemporaryDirectory(prefix="ai-background-test-") as temporary:
            log = Path(temporary) / "server.log"
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            pythonw = Path(sys.executable).with_name("pythonw.exe")
            code = (f"import sys; sys.path.insert(0, {str(ROOT)!r}); "
                    "from pathlib import Path; from ai_video_restore.background import run_background; "
                    f"run_background(port={port}, log_path=Path({str(log)!r}))")
            process = subprocess.Popen([str(pythonw), "-c", code], cwd=ROOT)
            url = f"http://127.0.0.1:{port}"
            try:
                for _ in range(100):
                    try:
                        with urllib.request.urlopen(url + "/health", timeout=1) as response:
                            self.assertTrue(json.load(response)["ok"])
                        break
                    except OSError:
                        self.assertIsNone(process.poll(), log.read_text(encoding="utf-8") if log.exists() else "No log")
                        time.sleep(0.1)
                else:
                    self.fail("Background service never became healthy")
                # pythonw has no console; child FFmpeg/GPU commands use CREATE_NO_WINDOW.
                ps = subprocess.run(["powershell.exe", "-NoProfile", "-Command",
                                     f"(Get-Process -Id {process.pid}).MainWindowHandle"],
                                    capture_output=True, text=True, check=True)
                self.assertEqual(ps.stdout.strip(), "0")
                # A second worker on the same port must fail and leave its reason in a file.
                conflict_log = Path(temporary) / "conflict.log"
                conflict = subprocess.run([str(pythonw), "-c", code.replace(str(log).replace("\\", "\\\\"),
                                                                          str(conflict_log).replace("\\", "\\\\"))],
                                          cwd=ROOT, timeout=15)
                self.assertNotEqual(conflict.returncode, 0)
                self.assertIn("OSError", conflict_log.read_text(encoding="utf-8"))
                request = urllib.request.Request(url + "/api/shutdown", data=b"{}",
                                                 headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(request, timeout=2) as response:
                    self.assertTrue(json.load(response)["ok"])
                self.assertEqual(process.wait(timeout=10), 0)
                self.assertIn("Background service PID=", log.read_text(encoding="utf-8"))
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
