from __future__ import annotations

import json
import shutil
import subprocess
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path


class MediaError(RuntimeError):
    pass


@dataclass(frozen=True)
class VideoMetadata:
    path: Path
    width: int
    height: int
    fps: Fraction
    duration: float
    frame_count: int
    video_codec: str
    audio_codec: str | None
    has_audio: bool
    is_vfr: bool

    def as_dict(self) -> dict[str, object]:
        return {
            "path": str(self.path),
            "width": self.width,
            "height": self.height,
            "fps": float(self.fps),
            "fps_fraction": f"{self.fps.numerator}/{self.fps.denominator}",
            "duration": self.duration,
            "frame_count": self.frame_count,
            "video_codec": self.video_codec,
            "audio_codec": self.audio_codec,
            "has_audio": self.has_audio,
            "is_vfr": self.is_vfr,
        }


def executable(name: str) -> str:
    found = shutil.which(name)
    if not found:
        raise MediaError(f"找不到 {name}，请重新运行安装脚本。")
    return found


def _fraction(value: str) -> Fraction:
    if not value or value == "0/0":
        return Fraction(0, 1)
    return Fraction(value)


def probe_video(path: str | Path, ffprobe: str | None = None) -> VideoMetadata:
    source = Path(path).expanduser().resolve()
    if not source.is_file():
        raise MediaError(f"视频不存在：{source}")
    probe = ffprobe or executable("ffprobe")
    command = [
        probe,
        "-v",
        "error",
        "-show_entries",
        "format=duration:stream=index,codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,nb_frames",
        "-of",
        "json",
        str(source),
    ]
    try:
        payload = json.loads(subprocess.check_output(command, text=True, encoding="utf-8"))
    except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
        raise MediaError(f"FFprobe 无法读取视频：{source.name}") from error

    streams = payload.get("streams", [])
    video = next((stream for stream in streams if stream.get("codec_type") == "video"), None)
    if not video:
        raise MediaError(f"文件中没有视频轨：{source.name}")
    audio = next((stream for stream in streams if stream.get("codec_type") == "audio"), None)
    duration = float(payload.get("format", {}).get("duration") or 0)
    avg_fps = _fraction(video.get("avg_frame_rate", "0/0"))
    nominal_fps = _fraction(video.get("r_frame_rate", "0/0"))
    fps = avg_fps or nominal_fps
    if fps <= 0 or duration <= 0:
        raise MediaError(f"视频缺少有效的帧率或时长：{source.name}")
    declared_frames = int(video.get("nb_frames") or 0)
    frame_count = declared_frames or max(1, round(duration * float(fps)))
    fps_gap = abs(float(nominal_fps) - float(avg_fps)) if nominal_fps and avg_fps else 0
    return VideoMetadata(
        path=source,
        width=int(video["width"]),
        height=int(video["height"]),
        fps=fps,
        duration=duration,
        frame_count=frame_count,
        video_codec=str(video.get("codec_name") or "unknown"),
        audio_codec=str(audio.get("codec_name")) if audio else None,
        has_audio=audio is not None,
        is_vfr=fps_gap > 0.01,
    )


def prefixed_output(source: str | Path, prefix: str, suffix: str = ".mp4") -> Path:
    path = Path(source).expanduser().resolve()
    return path.with_name(f"{prefix}+{path.stem}{suffix}")


def assert_safe_output(source: Path, output: Path) -> None:
    if source.resolve() == output.resolve():
        raise MediaError("输出路径不能覆盖源视频。")


def fitted_foreground_size(width: int, height: int, target_width: int = 1080, target_height: int = 1920) -> tuple[int, int]:
    scale = min(target_width / width, target_height / height)
    fitted_width = max(2, int(width * scale) // 2 * 2)
    fitted_height = max(2, int(height * scale) // 2 * 2)
    return fitted_width, fitted_height
