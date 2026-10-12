from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ai_video_restore.media import MediaError, assert_safe_output, fitted_foreground_size, prefixed_output


class OutputPathTests(unittest.TestCase):
    def test_prefix_is_added_in_source_folder(self) -> None:
        source = Path(tempfile.gettempdir()) / "原视频.mp4"
        self.assertEqual(prefixed_output(source, "高清"), source.resolve().with_name("高清+原视频.mp4"))

    def test_comparison_uses_requested_suffix(self) -> None:
        source = Path(tempfile.gettempdir()) / "clip.mov"
        self.assertEqual(prefixed_output(source, "对比", ".jpg"), source.resolve().with_name("对比+clip.jpg"))

    def test_source_cannot_be_overwritten(self) -> None:
        source = Path(tempfile.gettempdir()) / "clip.mp4"
        with self.assertRaises(MediaError):
            assert_safe_output(source, source)


class CanvasTests(unittest.TestCase):
    def test_portrait_is_contained_without_crop(self) -> None:
        self.assertEqual(fitted_foreground_size(1024, 1280), (1080, 1350))

    def test_vertical_video_is_contained_without_crop(self) -> None:
        width, height = fitted_foreground_size(720, 1270)
        self.assertLessEqual(width, 1080)
        self.assertLessEqual(height, 1920)
        self.assertAlmostEqual(width / height, 720 / 1270, places=2)


if __name__ == "__main__":
    unittest.main()
