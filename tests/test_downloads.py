"""Run with native Windows Python: real curl, local HTTP failure fixtures."""
import hashlib
import http.server
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
DATA = bytes(range(256)) * 32
DIGEST = hashlib.sha256(DATA).hexdigest()


@unittest.skipUnless(os.name == "nt", "requires native Windows PowerShell/curl")
class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ai-download-test-")
        self.path = Path(self.temp.name) / "download.bin"
        self.requests = []
        self.mode = "normal"
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                requested_range = self.headers.get("Range")
                owner.requests.append(requested_range)
                if owner.mode == "offline":
                    self.send_error(503)
                    return
                offset = int(requested_range.split("=")[1].split("-")[0]) if requested_range else 0
                if owner.mode == "ignore":
                    offset = 0
                self.send_response(206 if offset else 200)
                if offset:
                    self.send_header("Content-Range", f"bytes {offset}-{len(DATA)-1}/{len(DATA)}")
                self.send_header("Content-Length", str(len(DATA) - offset))
                self.end_headers()
                if owner.mode == "interrupt" and len(owner.requests) == 1:
                    self.wfile.write(DATA[:2048])
                    self.wfile.flush()
                    self.connection.shutdown(socket.SHUT_RDWR)
                else:
                    self.wfile.write(DATA[offset:])

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def invoke(self, digest=DIGEST):
        def quote(value):
            return "'" + str(value).replace("'", "''") + "'"
        command = (f"$ErrorActionPreference='Stop'; . {quote(ROOT / 'runtime-windows.ps1')}; "
                   f"Get-VerifiedDownload 'http://127.0.0.1:{self.server.server_port}/asset' "
                   f"{quote(self.path)} '{digest}'")
        return subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                               "-Command", command], capture_output=True, timeout=60)

    def test_interrupted_download_resumes(self):
        self.mode = "interrupt"
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.path.read_bytes(), DATA)
        self.assertEqual(self.requests, [None, "bytes=2048-"])

    def test_server_ignoring_ranges_restarts_safely(self):
        self.mode = "ignore"
        Path(str(self.path) + ".download").write_bytes(DATA[:2048])
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.path.read_bytes(), DATA)
        self.assertEqual(self.requests, ["bytes=2048-", None])

    def test_hash_failure_never_publishes(self):
        result = self.invoke("0" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.path.exists())
        self.assertEqual(len(self.requests), 3)

    def test_failed_retries_keep_partial(self):
        self.mode = "offline"
        partial = Path(str(self.path) + ".download")
        partial.write_bytes(DATA[:2048])
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(partial.read_bytes(), DATA[:2048])
        self.assertEqual(len(self.requests), 3)

    def test_verified_cache_is_offline(self):
        self.path.write_bytes(DATA)
        self.assertEqual(self.invoke().returncode, 0)
        self.assertEqual(self.requests, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
