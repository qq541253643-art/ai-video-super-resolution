from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from .engine import ProcessOptions, process_face_version, process_video


def main() -> int:
    parser = argparse.ArgumentParser(description="用 Real-ESRGAN 修复真人视频")
    parser.add_argument("inputs", nargs="+", type=Path, help="一个或多个视频路径")
    parser.add_argument("--tile", type=int, default=256, help="Real-ESRGAN tile 大小")
    parser.add_argument("--resource-mode", choices=["smooth", "full"], default="smooth", help="smooth 后台让行（默认），full 全速模式")
    parser.add_argument("--face", action="store_true", help="启用 CodeFormer 人脸增强")
    parser.add_argument("--face-only", action="store_true", help="复用已有高清版，仅追加 CodeFormer 人脸增强")
    parser.add_argument("--face-fidelity", type=float, default=0.9, help="CodeFormer 保真权重")
    parser.add_argument("--limit", type=float, default=None, help="仅处理前 N 秒")
    parser.add_argument("--keep-work", action="store_true", help="保留中间帧")
    parser.add_argument("--summary", type=Path, default=None, help="写入批次 JSON 报告")
    args = parser.parse_args()
    reports: list[dict[str, object]] = []
    batch_started = time.time()

    for index, source in enumerate(args.inputs, start=1):
        print(f"\n[{index}/{len(args.inputs)}] {source}", flush=True)

        def progress(payload: dict[str, object]) -> None:
            percent = int(float(payload.get("progress", 0)) * 100)
            stage = str(payload.get("stage", "处理中"))
            fps = payload.get("stage_fps")
            remaining = payload.get("remaining_seconds")
            details = f" · {float(fps):.2f} fps" if fps else ""
            details += f" · 剩余约 {int(float(remaining))} 秒" if remaining else ""
            print(f"\r{percent:3d}% {stage}{details}".ljust(100), end="", flush=True)

        options = ProcessOptions(
            tile=args.tile,
            face_enhance=args.face,
            face_fidelity=args.face_fidelity,
            duration_limit=args.limit,
            keep_work=args.keep_work,
            resource_mode=args.resource_mode,
        )
        report = process_face_version(source, options, progress) if args.face_only else process_video(source, options, progress)
        print("\n完成：" + str(report["outputs"]), flush=True)
        reports.append(report)

    summary = {
        "videos": reports,
        "batch_elapsed_seconds": round(time.time() - batch_started, 3),
    }
    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"批次报告：{args.summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
