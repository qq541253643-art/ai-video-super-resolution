"""Frame worker using the RealESRGANer bundled with pinned CodeFormer source."""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout
import io
from pathlib import Path
import sys


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--codeformer", type=Path, required=True)
    parser.add_argument("--tile", type=int, default=128)
    args = parser.parse_args()
    if args.tile < 32:
        raise ValueError("CUDA tile must be at least 32")
    sys.path.insert(0, str(args.codeformer))
    import cv2
    import numpy as np
    import torch
    from basicsr.archs.rrdbnet_arch import RRDBNet
    from basicsr.utils.realesrgan_utils import RealESRGANer

    if not torch.cuda.is_available():
        raise RuntimeError("CUDA unavailable; refusing CPU or non-AI fallback")
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23,
                    num_grow_ch=32, scale=4)
    upsampler = RealESRGANer(scale=4, model_path=str(args.weights), model=model,
                            tile=args.tile, tile_pad=10, pre_pad=10, half=True,
                            device=torch.device("cuda:0"))
    print(f"Real-ESRGAN x4plus CUDA / {torch.cuda.get_device_name(0)} / tile={args.tile}", flush=True)
    frames = sorted(args.input.glob("*.png"))
    if not frames:
        raise RuntimeError("No input frames")
    args.output.mkdir(parents=True, exist_ok=True)
    for index, source in enumerate(frames, start=1):
        # OpenCV's narrow Windows paths cannot reliably open Chinese filenames.
        image = cv2.imdecode(np.fromfile(str(source), dtype=np.uint8), cv2.IMREAD_COLOR)
        if image is None:
            raise RuntimeError(f"Cannot decode {source}")
        messages = io.StringIO()
        with redirect_stdout(messages):
            restored, _ = upsampler.enhance(image, outscale=4)
        # This upstream version prints tile RuntimeErrors instead of rethrowing.
        # Never publish an incomplete frame after OOM or another tile failure.
        if "Error" in messages.getvalue():
            raise RuntimeError(messages.getvalue() + "\nTry a smaller tile (128 or 64).")
        if restored.shape[:2] != (image.shape[0] * 4, image.shape[1] * 4):
            raise RuntimeError("Unexpected Real-ESRGAN output dimensions")
        ok, encoded = cv2.imencode(".png", restored)
        if not ok:
            raise RuntimeError(f"Cannot encode {source.name}")
        target = args.output / source.name
        partial = target.with_suffix(".partial")
        encoded.tofile(str(partial))
        partial.replace(target)
        print(f"Frame {index}/{len(frames)}", flush=True)


if __name__ == "__main__":
    main()
