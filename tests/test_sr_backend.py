from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from ai_video_restore import engine
from ai_video_restore.media import MediaError


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source, self.output = self.root / "input", self.root / "output"
        self.source.mkdir()
        self.output.mkdir()
        self.events = []
        self.metric = engine.StageMetric("test", 1, 1.0, 1.0)
        for name, value in {
            "runtime_root": self.root, "find_ncnn": self.root / "ncnn.exe",
            "find_models": self.root / "models", "find_codeformer": self.root / "CodeFormer",
            "find_cuda_weights": self.root / "RealESRGAN_x4plus.pth",
            "find_face_python": Path("python.exe"),
        }.items():
            mock = patch.object(engine, name, return_value=value)
            mock.start()
            self.addCleanup(mock.stop)
        self.addCleanup(self.temp.cleanup)

    def run_stage(self, backend=None):
        return engine.run_sr_stage(self.source, self.output, 1, 128, self.events.append, backend)

    def test_vulkan_success_does_not_run_cuda(self):
        with patch.object(engine, "_run_counted_stage", return_value=self.metric) as stage:
            self.assertEqual(self.run_stage()[1], "vulkan")
            self.assertEqual(stage.call_count, 1)
        self.assertEqual(engine.sr_backend(), "vulkan")

    def test_vulkan_init_failure_uses_real_cuda_worker_and_remembers(self):
        with patch.object(engine, "_run_counted_stage",
                          side_effect=[MediaError("vkCreateInstance failed -9\ninvalid gpu device"), self.metric]) as stage:
            self.assertEqual(self.run_stage()[1], "cuda")
            self.assertEqual(stage.call_count, 2)
            command = stage.call_args.args[0]
            self.assertTrue(command[1].endswith("cuda_realesrgan.py"))
            self.assertEqual(command[command.index("--tile") + 1], "128")
            self.assertIn("--weights", command)
        self.assertEqual(engine.sr_backend(), "cuda")
        self.assertIn("vkCreateInstance failed -9", self.events[0]["fallback_reason"])
        with patch.object(engine, "_run_counted_stage", return_value=self.metric) as stage:
            self.assertEqual(self.run_stage()[1], "cuda")
            self.assertEqual(stage.call_count, 1)
            self.assertTrue(stage.call_args.args[0][1].endswith("cuda_realesrgan.py"))

    def test_cuda_failure_does_not_mark_backend_success(self):
        with patch.object(engine, "_run_counted_stage",
                          side_effect=[MediaError("vkCreateInstance failed -9"), MediaError("CUDA out of memory")]):
            with self.assertRaisesRegex(MediaError, "CUDA out of memory"):
                self.run_stage()
        self.assertFalse((self.root / "realesrgan-backend.json").exists())

    def test_non_initialization_error_is_not_hidden(self):
        for message in ["Vulkan out of memory", "invalid image", "output frame count mismatch"]:
            with self.subTest(message=message), patch.object(engine, "_run_counted_stage", side_effect=MediaError(message)) as stage:
                with self.assertRaisesRegex(MediaError, message):
                    self.run_stage()
                self.assertEqual(stage.call_count, 1)

    def test_partial_outputs_are_not_mixed_between_backends(self):
        (self.output / "00000001.png").touch()
        with patch.object(engine, "_run_counted_stage", side_effect=MediaError("vkCreateInstance failed -9")) as stage:
            with self.assertRaises(MediaError):
                self.run_stage()
            self.assertEqual(stage.call_count, 1)

    def test_installer_can_probe_vulkan_again_after_driver_repair(self):
        engine.save_sr_backend("cuda", "previous failure")
        with patch.object(engine, "_run_counted_stage", return_value=self.metric) as stage:
            self.assertEqual(self.run_stage(backend="vulkan")[1], "vulkan")
            self.assertTrue(stage.call_args.args[0][0].endswith("ncnn.exe"))
        self.assertEqual(engine.sr_backend(), "vulkan")


if __name__ == "__main__":
    unittest.main()
