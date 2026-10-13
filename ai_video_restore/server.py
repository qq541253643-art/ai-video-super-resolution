from __future__ import annotations

import json
import mimetypes
import os
import queue
import shutil
import socket
import subprocess
import threading
import time
import traceback
import uuid
import webbrowser
from dataclasses import asdict, dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

from . import __version__
from .engine import ProcessOptions, find_codeformer, find_cuda_weights, find_ncnn, process_video, sr_backend
from .media import MediaError, probe_video
from .telemetry import read_gpu
from .control import Cancelled, JobControl


STATIC_ROOT = Path(__file__).resolve().parent / "static"
VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi", ".m4v", ".webm"}


@dataclass
class Job:
    id: str
    path: str
    name: str
    status: str = "queued"
    stage: str = "等待处理"
    progress: float = 0.0
    remaining_seconds: float | None = None
    stage_fps: float | None = None
    metadata: dict[str, object] = field(default_factory=dict)
    outputs: dict[str, str] = field(default_factory=dict)
    report_path: str | None = None
    error: str | None = None
    created_at: float = field(default_factory=time.time)
    started_at: float | None = None
    finished_at: float | None = None

    def public(self) -> dict[str, object]:
        return asdict(self)


class JobManager:
    def __init__(self) -> None:
        self.jobs: dict[str, Job] = {}
        self.pending: queue.Queue[tuple[str, ProcessOptions]] = queue.Queue()
        self.lock = threading.RLock()
        self.controls: dict[str, JobControl] = {}
        threading.Thread(target=self._worker, daemon=True).start()

    def add(self, paths: list[str], options: ProcessOptions) -> list[Job]:
        resolved: list[tuple[Path, dict[str, object]]] = []
        for raw in paths:
            path = Path(raw).expanduser().resolve()
            if not path.is_file() or path.suffix.lower() not in VIDEO_EXTENSIONS:
                raise MediaError(f"不支持的视频文件：{path}")
            resolved.append((path, probe_video(path).as_dict()))

        added: list[Job] = []
        for path, metadata in resolved:
            job_id = uuid.uuid4().hex[:16]
            job = Job(id=job_id, path=str(path), name=path.name, metadata=metadata)
            with self.lock:
                self.jobs[job_id] = job
                self.controls[job_id] = JobControl(options.resource_mode)
            self.pending.put((job_id, options))
            added.append(job)
        return added

    def action(self, job_id: str, action: str) -> None:
        if action not in {"pause", "resume", "cancel"}:
            raise MediaError("不支持的任务操作。")
        with self.lock:
            targets = list(self.jobs.values()) if job_id == "all" else [self.jobs.get(job_id)]
            if not targets or any(job is None for job in targets):
                raise MediaError("任务不存在，请刷新页面。")
            for job in targets:
                if job.status in {"completed", "failed", "cancelled"}:
                    continue
                control = self.controls[job.id]
                if action == "cancel":
                    control.cancel_requested.set()
                    job.status = "cancelling" if job.started_at else "cancelled"
                    job.stage = "正在终止并清理临时文件" if job.started_at else "已取消排队"
                    if not job.started_at:
                        job.finished_at = time.time()
                elif job.status != "cancelling":
                    if action == "pause":
                        control.pause_requested.set()
                        job.status = "pausing" if job.started_at else "paused"
                        job.stage = "当前小批次或步骤结束后暂停" if job.started_at else "已暂停排队"
                    else:
                        control.pause_requested.clear()
                        job.status = "running" if job.started_at else "queued"
                        job.stage = "继续处理" if job.started_at else "等待处理"
                job.remaining_seconds = None

    def snapshot(self) -> list[dict[str, object]]:
        with self.lock:
            return [job.public() for job in sorted(self.jobs.values(), key=lambda item: item.created_at)]

    def _worker(self) -> None:
        while True:
            job_id, options = self.pending.get()
            with self.lock:
                job = self.jobs[job_id]
                control = self.controls[job_id]
                if control.cancel_requested.is_set():
                    self.pending.task_done()
                    continue
                job.status = "paused" if control.pause_requested.is_set() else "running"
                job.started_at = time.time()

            def update(payload: dict[str, object]) -> None:
                with self.lock:
                    control_state = payload.get("control_state")
                    if control_state and job.status != "cancelling":
                        job.status = str(control_state)
                    for key in ("stage", "progress", "remaining_seconds", "stage_fps"):
                        if key in payload:
                            if key in {"stage", "remaining_seconds"} and job.status in {"pausing", "cancelling"}:
                                continue
                            setattr(job, key, payload[key])
                    if "outputs" in payload:
                        job.outputs = dict(payload["outputs"])

            try:
                report = process_video(job.path, options, update, control=control)
                with self.lock:
                    control.check_cancel()
                    job.status = "completed"
                    job.stage = "处理完成"
                    job.progress = 1.0
                    job.remaining_seconds = 0
                    job.outputs = dict(report["outputs"])
                    job.report_path = str(report["report_path"])
                    job.finished_at = time.time()
            except Cancelled:
                with self.lock:
                    job.status = "cancelled"
                    job.stage = "已终止，源视频未修改"
                    job.remaining_seconds = None
                    job.finished_at = time.time()
            except Exception as error:
                traceback.print_exc()
                with self.lock:
                    job.status = "failed"
                    job.stage = "处理失败"
                    job.error = str(error)
                    job.finished_at = time.time()
            finally:
                self.pending.task_done()


MANAGER = JobManager()
PICKER_LOCK = threading.Lock()


def _pick_files() -> list[str]:
    if os.name != "nt":
        return []
    if not PICKER_LOCK.acquire(blocking=False):
        raise MediaError("文件选择窗口已打开，请先选择视频或取消该窗口。")
    script = Path(__file__).resolve().parents[1] / "pick-videos-windows.ps1"
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", str(script)],
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            timeout=600,
        )
    except subprocess.TimeoutExpired as error:
        raise MediaError("文件选择窗口等待超过 10 分钟，已关闭。请重新点击选择视频。") from error
    except OSError as error:
        raise MediaError(f"无法启动 Windows 文件选择器：{error}") from error
    finally:
        PICKER_LOCK.release()
    if result.returncode:
        raise MediaError(result.stderr.strip() or "无法打开 Windows 文件选择器。")
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def _environment() -> dict[str, object]:
    gpu = read_gpu()
    backend = sr_backend()
    try:
        ncnn = str(find_cuda_weights() if backend == "cuda" else find_ncnn())
    except MediaError:
        ncnn = None
    try:
        codeformer = str(find_codeformer())
    except MediaError:
        codeformer = None
    return {
        "version": __version__,
        "gpu": asdict(gpu),
        "ffmpeg": shutil.which("ffmpeg"),
        "realesrgan": ncnn,
        "realesrgan_backend": backend,
        "codeformer": codeformer,
        "ready": bool(gpu.total_mb and ncnn and shutil.which("ffmpeg") and (backend != "cuda" or codeformer)),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "AIVideoRestore/" + __version__

    def log_message(self, format: str, *args: object) -> None:
        print(f"[{self.log_date_time_string()}] {format % args}")

    def _json(self, payload: object, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._security_headers()
        self.end_headers()
        self.wfile.write(body)

    def _security_headers(self) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'")

    def _trusted_request(self) -> bool:
        host = self.headers.get("Host", "").split(":", 1)[0].lower()
        if host not in {"127.0.0.1", "localhost"}:
            return False
        origin = self.headers.get("Origin")
        return not origin or origin.startswith("http://127.0.0.1:") or origin.startswith("http://localhost:")

    def _body(self) -> dict[str, object]:
        length = int(self.headers.get("Content-Length", "0"))
        if length > 1024 * 1024:
            raise MediaError("请求内容过大。")
        return json.loads(self.rfile.read(length).decode("utf-8")) if length else {}

    def do_GET(self) -> None:
        if not self._trusted_request():
            self._json({"error": "拒绝非本机请求。"}, status=403)
            return
        route = urlparse(self.path).path
        if route == "/api/status":
            self._json(_environment())
            return
        if route == "/api/jobs":
            self._json({"jobs": MANAGER.snapshot()})
            return
        if route == "/health":
            self._json({"ok": True, "app": "ai-video-restore", "version": __version__})
            return
        relative = "index.html" if route == "/" else unquote(route.lstrip("/"))
        target = (STATIC_ROOT / relative).resolve()
        if STATIC_ROOT not in target.parents and target != STATIC_ROOT:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        if not target.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        body = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", mimetypes.guess_type(target.name)[0] or "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self._security_headers()
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if not self._trusted_request():
            self._json({"error": "拒绝非本机请求。"}, status=403)
            return
        route = urlparse(self.path).path
        try:
            if route == "/api/pick":
                paths = _pick_files()
                files = [{"path": path, "metadata": probe_video(path).as_dict()} for path in paths]
                self._json({"files": files})
                return
            if route == "/api/jobs":
                body = self._body()
                paths = body.get("paths")
                if not isinstance(paths, list) or not paths:
                    raise MediaError("请至少选择一个视频。")
                options = ProcessOptions(
                    tile=max(32, min(512, int(body.get("tile", 256)))),
                    face_enhance=bool(body.get("face_enhance", False)),
                    face_fidelity=max(0.0, min(1.0, float(body.get("face_fidelity", 0.9)))),
                    duration_limit=float(body["duration_limit"]) if body.get("duration_limit") else None,
                    resource_mode=str(body.get("resource_mode", "smooth")),
                )
                JobControl(options.resource_mode)
                if options.face_enhance:
                    find_codeformer()
                jobs = MANAGER.add([str(path) for path in paths], options)
                self._json({"jobs": [job.public() for job in jobs]}, status=201)
                return
            if route == "/api/job-action":
                body = self._body()
                MANAGER.action(str(body.get("id", "")), str(body.get("action", "")))
                self._json({"ok": True})
                return
            if route == "/api/open-folder":
                body = self._body()
                path = Path(str(body.get("path", ""))).expanduser().resolve()
                folder = path if path.is_dir() else path.parent
                if os.name == "nt" and folder.is_dir():
                    subprocess.Popen(["explorer.exe", str(folder)])
                self._json({"ok": True})
                return
            if route == "/api/shutdown":
                if any(job["status"] not in {"completed", "failed", "cancelled"} for job in MANAGER.snapshot()):
                    self._json({"error": "正在处理视频，不能停止服务。"}, status=409)
                    return
                self._json({"ok": True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            self.send_error(HTTPStatus.NOT_FOUND)
        except (MediaError, ValueError, json.JSONDecodeError) as error:
            self._json({"error": str(error)}, status=400)


class LocalHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = False

    def server_bind(self) -> None:
        # Windows SO_REUSEADDR can permit two workers to bind the same port.
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


def run(host: str = "127.0.0.1", port: int = 8765, open_browser: bool = True) -> None:
    server = LocalHTTPServer((host, port), Handler)
    url = f"http://{host}:{port}"
    print(f"AI 视频高清修复 v{__version__}：{url}")
    if open_browser:
        threading.Timer(0.8, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    run()
