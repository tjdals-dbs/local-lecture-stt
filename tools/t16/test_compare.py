import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
import wave

from compare import CANDIDATES, RATE, WINDOW, file_digest, read, save, windows
from review import checked_run, render, stats, terminology_example


class ComparisonTests(unittest.TestCase):
    def test_frame_coverage_around_boundaries(self):
        for total in (8, WINDOW - 1, WINDOW, WINDOW + 1, WINDOW + 7, WINDOW + 8, WINDOW * 2 + 150):
            pcm = bytes(total * 4)
            parts = windows(pcm)
            self.assertEqual(parts[0]["startFrame"], 0)
            self.assertEqual(parts[-1]["endFrame"], total)
            self.assertEqual([p["endFrame"] for p in parts[:-1]], [p["startFrame"] for p in parts[1:]])
            for p in parts:
                self.assertGreaterEqual(p["endFrame"] - p["startFrame"], 8)
        for size in (0, 28, 33):
            with self.assertRaises(ValueError):
                windows(bytes(size))

    def test_rtf_frame_weighting_queue_and_missing_finals(self):
        plan = dict(frameCount=WINDOW + 16000, windows=windows(bytes((WINDOW + 16000) * 4)))
        empty = dict(kind="final", segments=[])
        rows = [dict(terminal=empty, terminalSeconds=n, timing=dict(inferenceSeconds=n, queueSeconds=0),
                     serviceSeconds=n) for n in (12, 2)]
        complete = stats(plan, rows)
        self.assertEqual(complete["rtf"], 14 / 21)
        self.assertEqual(complete["simWaitLast"], 11)
        self.assertIsNone(complete["partialP95"])
        self.assertEqual(complete["finalFrames"], plan["frameCount"])
        self.assertEqual(complete["emptyFinals"], 2)
        for tail in (None, dict(terminal=dict(kind="failed"), serviceSeconds=1)):
            result = stats(plan, [rows[0], tail])
            self.assertIsNone(result["rtf"])
            self.assertEqual(result["finalFrames"], WINDOW)
        self.assertIsNone(stats(plan, [None, rows[1]])["simWaitMax"])

    def test_extra_listening_example_excludes_scored_and_failed_windows(self):
        def final(text):
            return dict(terminal=dict(kind="final", segments=[dict(text=text)]))
        results = {"a": [final("A B C"), final("API"), final("GPU"), final("CPU")],
                   "b": [final("가"), None, final("gpu"), final("씨피유")]}
        self.assertEqual(terminology_example(results, [0]), 3)
        self.assertIsNone(terminology_example(results, [0, 3]))

    def test_review_restores_original_playback_time_and_rejects_shifted_terminal(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            sample = root / "sample-01"
            sample.mkdir()
            frames = WINDOW + RATE // 8
            source_offset_ms = 61_250
            source = root / "original.wav"

            def silence(path, count):
                with wave.open(str(path), "wb") as stream:
                    stream.setparams((1, 2, RATE, count, "NONE", ""))
                    stream.writeframes(bytes(count * 2))

            silence(source, source_offset_ms * 16 + frames)
            silence(sample / "listen.wav", frames)
            pcm = bytes(frames * 4)
            (sample / "audio.f32").write_bytes(pcm)
            plan = dict(source=str(source), sourceStartMs=source_offset_ms, sourceSHA256=file_digest(source),
                        pcmSHA256=file_digest(sample / "audio.f32"), frameCount=frames, languageMode="korean",
                        windows=windows(pcm), reviewIndices=[0, 1])
            save(sample / "plan.json", plan)
            jobs = [dict(sample=sample.name, candidate=name, pcmSHA256=plan["pcmSHA256"],
                         checksum=read(catalog)["entries"][0]["model"]["checksum"]) for name, catalog in CANDIDATES.items()]
            save(root / "matrix.json", dict(synthetic=True, jobs=jobs))
            render(root)
            page = (root / "REVIEW.html").read_text()
            self.assertIn('data-start="20.0" data-end="20.125"', page)
            self.assertIn("원본 01:21.250", page)
            self.assertIn("미실행 / 기록 누락", page)

            job = jobs[0]
            output = sample / job["candidate"]
            output.mkdir()
            context = dict(sequence=1, mediaStart=20_000, mediaEnd=20_125,
                           session=dict(model=dict(model=dict(checksum=job["checksum"]))))
            row = dict(index=1, window=plan["windows"][1], terminalSeconds=.1, serviceSeconds=.1,
                       terminal=dict(kind="final", segments=[], context=context))
            window_path = output / "window-1.json"
            save(window_path, row)
            _, summary = checked_run(root, job, plan)
            self.assertEqual(summary["finalFrames"], frames - WINDOW)
            window_path.unlink()
            context["mediaStart"] += source_offset_ms
            save(window_path, row)
            with self.assertRaisesRegex(ValueError, "restored sample time"):
                checked_run(root, job, plan)


if __name__ == "__main__":
    unittest.main()
