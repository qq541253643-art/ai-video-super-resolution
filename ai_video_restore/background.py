"""Windowless local service entry point; invoked using Windows pythonw.exe."""
from __future__ import annotations

import argparse
from datetime import datetime
import os
from pathlib import Path
import sys
import traceback


def run_background(port: int = 8765, log_path: Path | None = None) -> None:
    log_path = log_path or Path(__file__).resolve().parents[1] / ".runtime" / "logs" / "server.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8", buffering=1) as log:
        previous_stdout, previous_stderr = sys.stdout, sys.stderr
        sys.stdout = sys.stderr = log
        try:
            print(f"\n{datetime.now().isoformat()} Background service PID={os.getpid()}", flush=True)
            from .server import run
            run(port=port, open_browser=False)
        except BaseException:
            traceback.print_exc()
            raise
        finally:
            sys.stdout, sys.stderr = previous_stdout, previous_stderr


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    run_background(port=parser.parse_args().port)
