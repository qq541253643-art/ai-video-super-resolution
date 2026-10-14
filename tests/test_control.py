from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from ai_video_restore import control, engine, server
from ai_video_restore.media import MediaError
from ai_video_restore.telemetry import GpuSample


class ControlTests(unittest.TestCase):
    def test_smooth_limits_threads_tile_and_full_preserves_command(self):
        job = control.JobControl()
        args, env, _ = job.prepare_command(["ffmpeg.exe", "-i", "input.mp4", "out.mp4"])
        self.assertIn("-filter_complex_threads", args)
        self.assertLessEqual(int(env["OMP_NUM_THREADS"]), 2)
        self.assertEqual(job.tile(512), 128)
        self.assertEqual(job.chunk_size, 1)
        job = control.JobControl("full")
        self.assertEqual(job.chunk_size, 16)
        self.assertEqual(job.tile(512), 512)
        self.assertEqual(job.prepare_command(["ffmpeg", "in", "out"])[0], ["ffmpeg", "in", "out"])

    def test_resource_pressure_waits_then_resumes(self):
        job = control.JobControl()
        events = []
        job.notify = events.append
        with patch.object(control, "read_gpu", side_effect=[GpuSample(7000, 8192), GpuSample(2000, 8192), GpuSample(2000, 8192)]), \
             patch.object(control, "available_memory_mb", return_value=4096), \
             patch.object(job, "cpu_usage", return_value=0), \
             patch.object(job.cancel_requested, "wait"):
            job.checkpoint(gpu=True)
        self.assertEqual([e["control_state"] for e in events], ["waiting", "waiting", "running"])

    def test_busy_gpu_waits_even_with_free_vram_and_requires_stable_idle(self):
        job = control.JobControl()
        events = []
        job.notify = events.append
        samples = [GpuSample(1000, 8192, value) for value in (90, 10, 50, 10, 10)]
        with patch.object(control, "read_gpu", side_effect=samples), \
             patch.object(control, "available_memory_mb", return_value=8192), \
             patch.object(job, "cpu_usage", return_value=0), \
             patch.object(job.cancel_requested, "wait") as wait:
            job.checkpoint(gpu=True)
        self.assertEqual(wait.call_count, 4)
        self.assertIn("GPU", events[0]["stage"])
        self.assertIsNone(events[0]["remaining_seconds"])
        self.assertEqual(events[-1]["control_state"], "running")

    def test_cpu_and_memory_pressure_gate_cpu_steps_without_gpu_query(self):
        for cpu, memory, reason in (([80, 10, 10], [8192] * 3, "CPU"),
                                    ([0] * 3, [3000, 8192, 8192], "内存")):
            job = control.JobControl()
            events = []
            job.notify = events.append
            with patch.object(control, "read_gpu") as gpu, \
                 patch.object(control, "available_memory_mb", side_effect=memory), \
                 patch.object(job, "cpu_usage", side_effect=cpu), \
                 patch.object(job.cancel_requested, "wait"):
                job.checkpoint(resources=True)
            gpu.assert_not_called()
            self.assertIn(reason, events[0]["stage"])
            self.assertEqual(events[-1]["control_state"], "running")

    def test_cpu_times_use_deltas_and_tolerate_missing_samples(self):
        with patch.object(control, "system_cpu_times", side_effect=[(100, 200), (120, 300), None, (200, 500)]):
            job = control.JobControl()
            self.assertAlmostEqual(job.cpu_usage(), 80)
            self.assertIsNone(job.cpu_usage())
            self.assertIsNone(job.cpu_usage())

    def test_full_mode_does_not_sample_or_rest(self):
        job = control.JobControl("full")
        with patch.object(control, "read_gpu") as gpu, patch.object(job, "cpu_usage") as cpu, \
             patch.object(job.cancel_requested, "wait") as wait:
            job.checkpoint(gpu=True, resources=True)
            job.yield_after_batch(20)
        gpu.assert_not_called()
        cpu.assert_not_called()
        wait.assert_not_called()

    def test_missing_telemetry_does_not_block(self):
        job = control.JobControl()
        with patch.object(control, "read_gpu", return_value=GpuSample()), \
             patch.object(control, "available_memory_mb", return_value=None), \
             patch.object(job, "cpu_usage", return_value=None), \
             patch.object(job.cancel_requested, "wait") as wait:
            job.checkpoint(gpu=True)
        wait.assert_not_called()

    def test_rest_is_proportional_with_minimum_and_records_elapsed(self):
        for elapsed, expected in ((0.1, 2), (4, 6)):
            job = control.JobControl()
            clock = [100.0]
            events = []
            job.notify = events.append
            with patch.object(control.time, "monotonic", side_effect=lambda: clock[0]), \
                 patch.object(job.cancel_requested, "wait", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
                job.yield_after_batch(elapsed)
            self.assertEqual(job.yield_seconds, expected)
            self.assertEqual(events[-1]["control_state"], "running")
            self.assertIn("模型已退出", events[0]["stage"])

    def test_cancel_during_pressure_or_rest_is_responsive(self):
        for pressure in (True, False):
            job = control.JobControl()
            job.notify = lambda event: job.cancel_requested.set()
            with patch.object(control, "read_gpu", return_value=GpuSample(7000, 8192)), \
                 patch.object(control, "available_memory_mb", return_value=8192), \
                 patch.object(job, "cpu_usage", return_value=0):
                with self.assertRaises(control.Cancelled):
                    job.checkpoint(gpu=True) if pressure else job.yield_after_batch(10)

    def test_pause_during_rest_stays_paused_until_resume(self):
        job = control.JobControl()
        clock = [100.0]
        events = []

        def notify(event):
            events.append(event)
            if len(events) == 1:
                job.pause_requested.set()
            elif event["control_state"] == "paused" and clock[0] >= 104:
                job.pause_requested.clear()

        job.notify = notify
        with patch.object(control.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(job.cancel_requested, "wait", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            job.yield_after_batch(0.1)
        self.assertGreaterEqual(job.yield_seconds, 4)
        self.assertIn("paused", [e["control_state"] for e in events])
        self.assertEqual(events[-1]["control_state"], "running")

    def test_pause_and_cancel_while_waiting(self):
        job = control.JobControl()
        job.pause_requested.set()
        job.notify = lambda event: job.cancel_requested.set()
        with self.assertRaises(control.Cancelled):
            job.checkpoint()

    def test_cancel_kills_running_child(self):
        job = control.JobControl("full")
        token = control.CURRENT.set(job)
        timer = threading.Timer(0.3, job.cancel_requested.set)
        timer.start()
        start = time.monotonic()
        try:
            with self.assertRaises(control.Cancelled):
                engine._run([sys.executable, "-c", "import time; time.sleep(30)"])
            self.assertLess(time.monotonic() - start, 3)
        finally:
            timer.cancel()
            control.CURRENT.reset(token)

    def test_disk_reserve(self):
        job = control.JobControl()
        job.disk_paths = [Path(tempfile.gettempdir())]
        with patch.object(control.shutil, "disk_usage", return_value=type("Disk", (), {"free": 100})()):
            with self.assertRaisesRegex(MediaError, "2 GB"):
                job.checkpoint()

    def test_chunk_oom_retries_smaller_tile_and_moves_complete_frames(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inp, out = root / "input", root / "output"
            inp.mkdir()
            for i in range(6):
                (inp / f"{i:08d}.png").touch()
            calls = []

            def stage(command, output, count, *args):
                tile = int(command[command.index("-t") + 1])
                calls.append(tile)
                output.mkdir(exist_ok=True)
                if len(calls) == 1:
                    (output / "partial.png").touch()
                    raise MediaError("Vulkan out of memory")
                source = Path(command[command.index("-i") + 1])
                for frame in source.glob("*.png"):
                    (output / frame.name).touch()
                return engine.StageMetric("test", count, 1, count)

            job = control.JobControl()
            token = control.CURRENT.set(job)
            try:
                with patch.object(job, "checkpoint"), patch.object(job, "yield_after_batch") as rest, \
                     patch.object(engine, "_execute_counted_stage", side_effect=stage):
                    result = engine._run_counted_stage(["ncnn", "-i", str(inp), "-o", str(out), "-t", "128"],
                                                       out, 6, "test", 0, 1, lambda event: None)
                self.assertEqual(calls, [128] + [64] * 6)
                self.assertEqual(rest.call_count, 6)
                self.assertEqual(result.frames, 6)
                self.assertEqual(sorted(x.name for x in out.iterdir()), sorted(x.name for x in inp.iterdir()))
            finally:
                control.CURRENT.reset(token)

    def test_manager_cancel_queued_and_pause_resume(self):
        manager = server.JobManager.__new__(server.JobManager)
        manager.lock = threading.RLock()
        manager.jobs = {"one": server.Job("one", "in.mp4", "in.mp4")}
        manager.controls = {"one": control.JobControl()}
        manager.action("one", "pause")
        self.assertEqual(manager.jobs["one"].status, "paused")
        manager.action("one", "resume")
        self.assertEqual(manager.jobs["one"].status, "queued")
        manager.action("all", "cancel")
        self.assertEqual(manager.jobs["one"].status, "cancelled")
        self.assertTrue(manager.controls["one"].cancel_requested.is_set())
        with self.assertRaises(MediaError):
            manager.action("missing", "cancel")

    def test_paused_task_cannot_be_shutdown_and_cancelled_can(self):
        from http.server import ThreadingHTTPServer
        from urllib.error import HTTPError
        from urllib.request import Request, urlopen
        import json

        httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        worker = threading.Thread(target=httpd.serve_forever, daemon=True)
        worker.start()
        url = f"http://127.0.0.1:{httpd.server_port}/api/shutdown"
        try:
            for status in ("queued", "running", "pausing", "paused", "waiting", "cancelling"):
                with self.subTest(status=status), patch.object(server.MANAGER, "snapshot", return_value=[{"status": status}]):
                    with self.assertRaises(HTTPError) as failure:
                        urlopen(Request(url, data=b"{}"), timeout=3)
                    self.assertEqual(failure.exception.code, 409)
                    failure.exception.close()
            with patch.object(server.MANAGER, "snapshot", return_value=[{"status": "cancelled"}]):
                with urlopen(Request(url, data=b"{}"), timeout=3) as response:
                    self.assertTrue(json.load(response)["ok"])
        finally:
            httpd.shutdown()
            httpd.server_close()
            worker.join(3)

    def test_failed_spawn_stops_monitor(self):
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(engine, "GpuMonitor") as monitor, \
             patch.object(engine.subprocess, "Popen", side_effect=OSError("missing executable")):
            with self.assertRaises(OSError):
                engine._execute_counted_stage(["missing"], Path(temporary), 1, "test", 0, 1, lambda event: None)
            monitor.return_value.start.return_value.stop.assert_called_once()


class QualityTests(unittest.TestCase):
    def test_negative_ssim_is_not_treated_as_positive(self):
        with patch.object(engine, "_run", return_value=subprocess.CompletedProcess([], 0, "All:-0.016")):
            with self.assertRaisesRegex(MediaError, "-0.016"):
                engine._validate_ai_alignment("ffmpeg", Path("a"), Path("b"), 1280, 720)

    def test_bad_vulkan_uses_cuda_but_bad_cuda_stops_and_keeps_evidence(self):
        for cuda_ok in (True, False):
            with self.subTest(cuda_ok=cuda_ok), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                original = root / "job" / "original"
                original.mkdir(parents=True)
                # Only IHDR dimensions are read here; mocked inference does not decode.
                (original / "00000001.png").write_bytes(b"\0" * 16 + struct.pack(">II", 720, 1280))
                backends = []

                def stage(source, output, count, tile, callback, backend):
                    backends.append(backend)
                    output.mkdir(exist_ok=True)
                    for frame in source.glob("*.png"):
                        (output / frame.name).touch()
                    return engine.StageMetric("test", count, 1, count), backend

                def validate(ffmpeg, source, output, width, height):
                    self.assertEqual((width, height), (720, 1280))
                    if "quality-0" in str(output) or not cuda_ok:
                        raise MediaError("SSIM 0.016")
                    return .96

                with patch.object(engine, "run_sr_stage", side_effect=stage), \
                     patch.object(engine, "sr_backend", return_value="vulkan"), \
                     patch.object(engine, "data_root", return_value=root), \
                     patch.object(engine, "_validate_ai_alignment", side_effect=validate):
                    call = lambda: engine._checked_sr("ffmpeg", original, root / "output", 1,
                                                      engine.ProcessOptions(), lambda event: None)
                    if cuda_ok:
                        self.assertEqual(call()[1:], ("cuda", .96))
                        self.assertEqual(backends, ["vulkan", "cuda", "cuda"])
                    else:
                        with self.assertRaisesRegex(MediaError, "诊断文件"):
                            call()
                        self.assertEqual(backends, ["vulkan", "cuda"])
                        self.assertTrue((root / "diagnostics/job/quality.json").is_file())


if __name__ == "__main__":
    unittest.main()
