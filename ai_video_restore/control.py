"""Cooperative job control. Pauses release model workers at chunk boundaries."""
from __future__ import annotations

from contextvars import ContextVar
import ctypes
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time

from .media import MediaError
from .telemetry import read_gpu


class Cancelled(RuntimeError):
    pass


CURRENT: ContextVar["JobControl | None"] = ContextVar("job_control", default=None)


def available_memory_mb() -> int | None:
    if os.name != "nt":
        return None

    class MemoryStatus(ctypes.Structure):
        _fields_ = [("length", ctypes.c_ulong), ("load", ctypes.c_ulong)] + [
            (name, ctypes.c_ulonglong) for name in (
                "total", "available", "page_total", "page_available",
                "virtual_total", "virtual_available", "extended")]

    status = MemoryStatus()
    status.length = ctypes.sizeof(status)
    if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
        return status.available // (1024 * 1024)
    return None


class JobControl:
    def __init__(self, mode: str = "smooth") -> None:
        if mode not in {"smooth", "full"}:
            raise MediaError("运行模式只能是 smooth 或 full。")
        self.mode = mode
        self.pause_requested = threading.Event()
        self.cancel_requested = threading.Event()
        self.notify = lambda event: None
        self.disk_paths: list[Path] = []
        self.last_disk_check = 0.0
        self.min_tile = 512

    @property
    def threads(self) -> int:
        return max(1, min(4, (os.cpu_count() or 2) // 2))

    def check_cancel(self) -> None:
        if self.cancel_requested.is_set():
            raise Cancelled("任务已终止，源视频未修改。")

    def check_disk(self) -> None:
        if time.monotonic() - self.last_disk_check < 2:
            return
        self.last_disk_check = time.monotonic()
        for path in self.disk_paths:
            if shutil.disk_usage(path).free < 2 * 1024**3:
                raise MediaError(f"磁盘剩余空间不足 2 GB，已停止处理：{path}。请释放空间后重试。")

    def checkpoint(self, *, gpu: bool = False) -> None:
        self.check_cancel()
        waiting = False
        while True:
            self.check_cancel()
            self.check_disk()
            if self.pause_requested.is_set():
                self.notify({"control_state": "paused", "stage": "已暂停，可继续或终止"})
            elif self.mode == "smooth" and gpu:
                sample = read_gpu()
                memory = available_memory_mb()
                # Admission target, not a reservation: other applications can
                # allocate memory immediately after this sample.
                if sample.total_mb and sample.total_mb - sample.used_mb < 2304:
                    self.notify({"control_state": "waiting", "stage": "等待空闲显存（目标至少 2.25 GB）"})
                elif memory is not None and memory < 2048:
                    self.notify({"control_state": "waiting", "stage": "等待可用内存（目标至少 2 GB）"})
                else:
                    break
            else:
                break
            waiting = True
            self.cancel_requested.wait(0.5)
        if waiting:
            self.notify({"control_state": "running", "stage": "继续处理"})

    def tile(self, requested: int) -> int:
        value = min(requested, 128) if self.mode == "smooth" else requested
        self.min_tile = min(self.min_tile, value)
        return value

    def prepare_command(self, command: list[str]) -> tuple[list[str], dict[str, str], int]:
        command = list(command)
        environment = os.environ.copy()
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        if self.mode == "smooth":
            flags |= getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0)
            for key in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS"):
                environment[key] = str(self.threads)
            if Path(command[0]).stem.lower() == "ffmpeg":
                command[1:1] = ["-threads", str(self.threads), "-filter_threads", "1", "-filter_complex_threads", "1"]
                command[-1:-1] = ["-threads", str(self.threads)]
        return command, environment, flags
