from __future__ import annotations

import csv
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass
class GpuSample:
    used_mb: int = 0
    total_mb: int = 0
    utilization: int = 0
    name: str = "未检测到 NVIDIA GPU"


def _nvidia_smi() -> str | None:
    found = shutil.which("nvidia-smi")
    if found:
        return found
    windows_path = r"C:\Windows\System32\nvidia-smi.exe"
    return windows_path if Path(windows_path).is_file() else None


def read_gpu() -> GpuSample:
    command = _nvidia_smi()
    if not command:
        return GpuSample()
    try:
        output = subprocess.check_output(
            [
                command,
                "--query-gpu=name,memory.used,memory.total,utilization.gpu",
                "--format=csv,noheader,nounits",
            ],
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=5,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        row = next(csv.reader([output.strip().splitlines()[0]], skipinitialspace=True))
        return GpuSample(name=row[0].strip(), used_mb=int(row[1]), total_mb=int(row[2]), utilization=int(row[3]))
    except (OSError, subprocess.SubprocessError, ValueError, IndexError, StopIteration):
        return GpuSample()


class GpuMonitor:
    def __init__(self, interval: float = 0.25) -> None:
        self.interval = interval
        self.baseline = read_gpu()
        self.peak = self.baseline
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> "GpuMonitor":
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        return self

    def _run(self) -> None:
        while not self._stop.wait(self.interval):
            sample = read_gpu()
            if sample.used_mb > self.peak.used_mb:
                self.peak = sample

    def stop(self) -> dict[str, int | str]:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
        return {
            "gpu": self.peak.name,
            "baseline_vram_mb": self.baseline.used_mb,
            "peak_vram_mb": self.peak.used_mb,
            "peak_delta_vram_mb": max(0, self.peak.used_mb - self.baseline.used_mb),
            "total_vram_mb": self.peak.total_mb,
        }


class Stopwatch:
    def __enter__(self) -> "Stopwatch":
        self.started = time.perf_counter()
        self.elapsed = 0.0
        return self

    def __exit__(self, *_: object) -> None:
        self.elapsed = time.perf_counter() - self.started
