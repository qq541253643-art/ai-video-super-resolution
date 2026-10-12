"""Small real-inference installation check, not a video-quality benchmark."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

from . import __version__
from .engine import find_codeformer, find_models, find_ncnn, runtime_root
from .media import executable, probe_video
from .server import Handler


def run_command(args: list[str], *, cwd: Path | None = None) -> None:
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=600)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}\n{result.stdout}\n{result.stderr}")
    if result.stdout:
        print(result.stdout, flush=True)


def run(skip_face: bool = False) -> dict:
    started = time.monotonic()
    ffmpeg = executable("ffmpeg")
    checks: list[str] = []
    # Isolate generated inputs and outputs; never touch the user's videos.
    with tempfile.TemporaryDirectory(prefix="ai-selftest-") as temporary:
        work = Path(temporary)
        source, restored, video = work / "input.png", work / "output.png", work / "test.mp4"
        run_command([ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i",
                     "testsrc2=size=64x64:rate=1", "-frames:v", "1", str(source)])
        ncnn = find_ncnn()
        run_command([str(ncnn), "-i", str(source), "-o", str(restored), "-m",
                     str(find_models(ncnn)), "-n", "realesrgan-x4plus", "-s", "4", "-t", "128", "-g", "0"])
        if not restored.is_file():
            raise RuntimeError("Real-ESRGAN did not produce an image")
        run_command([ffmpeg, "-v", "error", "-y", "-loop", "1", "-i", str(restored),
                     "-t", "0.2", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(video)])
        metadata = probe_video(video)
        if (metadata.width, metadata.height, metadata.video_codec) != (256, 256, "h264"):
            raise RuntimeError("Real-ESRGAN 4x / H.264 output validation failed")
        checks.extend(["Real-ESRGAN Vulkan inference", "FFmpeg H.264 encode + FFprobe"])
        print("PASS: Real-ESRGAN actual 4x inference and H.264 encoding", flush=True)

    if not skip_face:
        codeformer = find_codeformer()
        code = """
import torch
from basicsr.archs.codeformer_arch import CodeFormer
from facelib.utils.face_restoration_helper import FaceRestoreHelper
assert torch.cuda.is_available(), 'CUDA unavailable'
net = CodeFormer(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9,
                 connect_list=['32', '64', '128', '256']).cuda().eval()
state = torch.load('weights/CodeFormer/codeformer.pth', map_location='cpu', weights_only=False)
net.load_state_dict(state['params_ema'])
del state
with torch.inference_mode():
    result = net(torch.zeros(1, 3, 512, 512, device='cuda'), w=0.9, adain=True)[0]
assert tuple(result.shape) == (1, 3, 512, 512) and torch.isfinite(result).all()
del result, net
torch.cuda.empty_cache()
helper = FaceRestoreHelper(1, face_size=512, crop_ratio=(1, 1),
                          det_model='retinaface_mobile0.25', save_ext='png',
                          use_parse=True, device='cuda')
print('PASS: CodeFormer CUDA forward, face detector and parser loaded; GPU=' + torch.cuda.get_device_name())
"""
        run_command([sys.executable, "-c", code], cwd=codeformer)
        checks.append("CodeFormer CUDA inference + detector/parser loading")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        url = f"http://127.0.0.1:{server.server_port}"
        with urllib.request.urlopen(url + "/health", timeout=10) as response:
            assert json.load(response)["ok"]
        with urllib.request.urlopen(url + "/api/status", timeout=15) as response:
            status = json.load(response)
            assert status["ready"] and status["version"] == __version__, status
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    checks.append("panel health and environment API")
    report = {"version": __version__, "ok": True, "checks": checks,
              "seconds": round(time.monotonic() - started, 2)}
    runtime_root().mkdir(parents=True, exist_ok=True)
    (runtime_root() / "install-selftest.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2), flush=True)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-face", action="store_true")
    run(parser.parse_args().skip_face)
