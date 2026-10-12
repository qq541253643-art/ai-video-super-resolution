import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == "nt", "requires Windows PowerShell")
class InstallFailureTests(unittest.TestCase):
    def test_failure_preserves_log_and_does_not_create_shortcut(self):
        with tempfile.TemporaryDirectory(prefix="ai-install-failure-") as temporary:
            folder = Path(temporary)
            setup = b"throw 'EXPECTED_TEST_FAILURE'\n"
            manifest = {"files": [{"path": "setup-windows.ps1",
                                   "sha256": hashlib.sha256(setup).hexdigest()}]}
            archive = folder / "fixture.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("snapshot/setup-windows.ps1", setup)
                bundle.writestr("snapshot/manifest.json", json.dumps(manifest))

            def quote(value):
                return "'" + str(value).replace("'", "''") + "'"

            # Only replace the repository download. Execute the real installer,
            # transcript, manifest validation, setup failure and cleanup path.
            command = ("function Invoke-WebRequest { param($UseBasicParsing,$TimeoutSec,$Headers,$Uri,$OutFile) "
                       f"Copy-Item -LiteralPath {quote(archive)} -Destination $OutFile }}; "
                       f"& {quote(ROOT / 'install-windows.ps1')} -NoOpen "
                       f"-InstallDir {quote(folder / 'app')} -DesktopDir {quote(folder / 'desktop')}")
            # Switch binding must match Invoke-WebRequest's original signature.
            command = command.replace("param($UseBasicParsing", "param([switch]$UseBasicParsing")
            result = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                                     "-Command", command], capture_output=True, timeout=60)
            self.assertNotEqual(result.returncode, 0)
            logs = list((folder / "desktop").glob("AI-install-*.txt"))
            self.assertEqual(len(logs), 1, result.stderr)
            self.assertIn("EXPECTED_TEST_FAILURE", logs[0].read_text(encoding="utf-8-sig"))
            self.assertFalse(list((folder / "desktop").glob("*.lnk")))
            self.assertTrue((folder / "app" / "setup-windows.ps1").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
