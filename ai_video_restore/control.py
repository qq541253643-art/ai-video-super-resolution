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


def system_cpu_times() -> tuple[int, int] | None:
    if os.name != "nt":
        return None
    idle, kernel, user = (ctypes.c_ulonglong() for _ in range(3))
    if ctypes.windll.kernel32.GetSystemTimes(
        ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user)
    ):
        # Windows kernel time includes idle time.
        return idle.value, kernel.value + user.value
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
        self.last_cpu_times = system_cpu_times()
        self.yield_seconds = 0.0

    @property
    def chunk_size(self) -> int:
        return 1 if self.mode == "smooth" else 16

    @property
    def threads(self) -> int:
        return max(1, min(2, (os.cpu_count() or 2) // 4))

    def cpu_usage(self) -> float | None:
        current = system_cpu_times()
        previous, self.last_cpu_times = self.last_cpu_times, current
        if current is None or previous is None or current[1] <= previous[1]:
            return None
        return max(0.0, min(100.0, 100 * (1 - (current[0] - previous[0]) / (current[1] - previous[1]))))

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

    def checkpoint(self, *, gpu: bool = False, resources: bool = False) -> None:
        self.check_cancel()
        waiting = False
        pressure_seen = False
        clear_samples = 0
        while True:
            self.check_cancel()
            self.check_disk()
            if self.pause_requested.is_set():
                self.notify({"control_state": "paused", "stage": "已暂停，可继续或终止", "remaining_seconds": None})
                clear_samples = 0
            elif self.mode == "smooth" and (gpu or resources):
                sample = read_gpu() if gpu else None
                memory = available_memory_mb()
                cpu = self.cpu_usage()
                reason = None
                # Admission target, not a reservation: other applications can
                # allocate memory immediately after this sample.
                if sample and sample.total_mb and sample.total_mb - sample.used_mb < 2304:
                    reason = "等待空闲显存（目标至少 2.25 GB）"
                elif memory is not None and memory < 4096:
                    reason = "后台让行：等待可用内存（目标至少 4 GB）"
                elif sample and sample.utilization >= 40:
                    reason = f"后台让行：GPU 正忙（{sample.utilization}%），稍后重试"
                elif cpu is not None and cpu >= 70:
                    reason = f"后台让行：CPU 正忙（{cpu:.0f}%），稍后重试"
                if reason:
                    pressure_seen, clear_samples = True, 0
                elif pressure_seen:
                    clear_samples += 1
                    if clear_samples >= 2:
                        break
                    reason = "后台让行：确认资源已空闲"
                else:
                    break
                self.notify({"control_state": "waiting", "stage": reason, "remaining_seconds": None})
            else:
                break
            waiting = True
            self.cancel_requested.wait(1.0)
        if waiting:
            self.notify({"control_state": "running", "stage": "继续处理"})

    def yield_after_batch(self, elapsed: float) -> None:
        if self.mode != "smooth":
            return
        # The model process has exited. Leave at least 60% of each model/rest
        # cycle to other applications, not a hard cap on GPU utilization.
        started = time.monotonic()
        deadline = started + max(2.0, elapsed * 1.5)
        try:
            while True:
                self.checkpoint()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.notify({"control_state": "waiting", "stage": f"后台让行：模型已退出，休息 {remaining:.0f} 秒", "remaining_seconds": None})
                self.cancel_requested.wait(min(0.5, remaining))
        finally:
            self.yield_seconds += time.monotonic() - started
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
