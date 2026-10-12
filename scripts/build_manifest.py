from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FILES = [
    "VERSION",
    "LICENSE",
    "README.md",
    "pyproject.toml",
    "install.ps1",
    "install-windows.ps1",
    "setup-windows.ps1",
    "start-windows.ps1",
    "test-5s.ps1",
    "打开AI视频高清修复.cmd",
    "ai_video_restore/__init__.py",
    "ai_video_restore/__main__.py",
    "ai_video_restore/cli.py",
    "ai_video_restore/engine.py",
    "ai_video_restore/media.py",
    "ai_video_restore/server.py",
    "ai_video_restore/telemetry.py",
    "ai_video_restore/static/index.html",
    "ai_video_restore/static/styles.css",
    "ai_video_restore/static/app.js",
]


def main() -> None:
    entries = []
    for relative in FILES:
        path = ROOT / relative
        entries.append({"path": relative, "sha256": hashlib.sha256(path.read_bytes()).hexdigest().upper()})
    payload = {
        "version": (ROOT / "VERSION").read_text(encoding="utf-8").strip(),
        "runtime_version": "1",
        "files": entries,
    }
    (ROOT / "manifest.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
