"""Real SIGKILL/relaunch tests of production storage and recovery code.

Run with --probe <built stt-benchmark> --results <outside-repository JSON>.
Only generated fixtures under owned /private/tmp/T26-* directories are touched.
This does not establish physical microphone, lid, TCC or power-loss durability.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import unittest

PROBE = None
MEASUREMENTS = []
SOURCE = "recovery/audio.recovery.mov"
JOURNAL = "recovery/transcript.journal.jsonl"
CHECKPOINT = "recovery/finalization.checkpoint.json"


class RecoveryProcessTests(unittest.TestCase):
    def fixture(self):
        return tempfile.TemporaryDirectory(prefix="T26-", dir="/private/tmp")

    def invoke(self, mode, base, boundary="none", milliseconds=None):
        args = [str(PROBE), "recovery-probe", mode, str(base), boundary]
        if milliseconds is not None:
            args.append(str(milliseconds))
        result = subprocess.run(args, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stderr[-5000:])
        return json.loads(result.stdout.strip())

    def kill_at(self, mode, base, boundary, milliseconds=None):
        args = [str(PROBE), "recovery-probe", mode, str(base), boundary]
        if milliseconds is not None:
            args.append(str(milliseconds))
        # stderr goes to a file so a noisy AVFoundation diagnostic cannot fill
        # a pipe and deadlock the acknowledged boundary.
        with tempfile.TemporaryFile() as errors:
            child = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(child.stdout, selectors.EVENT_READ)
                    self.assertTrue(selector.select(60), "child never acknowledged the requested boundary")
                    line = child.stdout.readline()
                if not line:
                    child.wait(timeout=5)
                    errors.seek(0)
                    self.fail(errors.read().decode(errors="replace")[-5000:])
                reached = json.loads(line)
                self.assertEqual(reached["boundary"], boundary)
                os.kill(child.pid, signal.SIGKILL)
                self.assertEqual(child.wait(timeout=10), -signal.SIGKILL)
                return reached
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=10)
                child.stdin.close()
                child.stdout.close()

    def session(self, base):
        folders = list((Path(base) / "root").iterdir())
        self.assertEqual(len(folders), 1)
        return folders[0]

    def hashes(self, directory):
        return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(directory.rglob("*")) if p.is_file()}

    def assert_ready(self, report, outcome="completed", steps=7):
        self.assertEqual(report["status"], "completed" if outcome == "completed" else "interrupted")
        self.assertEqual(report["outcome"], outcome)
        self.assertEqual(len(report["checkpoints"]), steps)
        self.assertEqual(report["catalogRows"], 1)
        media = report["media"]
        self.assertEqual((media["codec"], media["sampleRate"], media["channels"]), ("AAC-LC", 48000, 1))
        self.assertLess(media["maximumGapSeconds"], 0.0001)
        self.assertLess(abs(media["timelineStartSeconds"]), 0.08)
        for endpoint in [media["first"], media["last"]]:
            self.assertGreater(endpoint["byteCount"], 0)
            self.assertGreater(endpoint["rms"], 0.01)
            self.assertGreater(endpoint["zeroCrossings"], 0)
        segments = report["transcript"]["segments"]
        self.assertEqual([s["text"] for s in segments], ["synthetic 0", "synthetic 1", "synthetic 2"])
        self.assertEqual(len({s["id"] for s in segments}), 3)

    def assert_repeat_stable(self, base, first, outcome="completed", steps=7):
        directory = self.session(base)
        before = self.hashes(directory)
        previous = None
        for _ in range(3):
            again = self.invoke("recover", base)
            self.assert_ready(again, outcome, steps)
            self.assertEqual(again["transcript"], first["transcript"])
            self.assertEqual(again["media"]["payloadSHA256"], first["media"]["payloadSHA256"])
            after = self.hashes(directory)
            # Interrupted -> settled is a new diagnostic episode. It may append
            # one audit pair, but must not duplicate events or rewrite content.
            self.assertEqual({k: v for k, v in after.items() if k != "events.jsonl"},
                             {k: v for k, v in before.items() if k != "events.jsonl"})
            event_file = directory / "events.jsonl"
            events = [json.loads(line) for line in event_file.read_text().splitlines()] if event_file.exists() else []
            self.assertEqual(len(events), len({e["eventId"] for e in events}))
            episodes = [(e["kind"], e.get("detail", {}).get("code")) for e in events]
            self.assertEqual(len(episodes), len(set(episodes)))
            if previous is not None:
                self.assertEqual(after, previous, "settled recovery must also leave the audit log unchanged")
            previous = after

    def test_normal_stop_preserves_full_timeline(self):
        with self.fixture() as base:
            self.invoke("seed", base, "normal", 22500)
            source = (self.session(base) / SOURCE).read_bytes()
            first = self.invoke("recover", base)
            self.assert_ready(first)
            self.assertAlmostEqual(first["media"]["durationSeconds"], 22.5, delta=0.08)
            self.assertEqual((self.session(base) / SOURCE).read_bytes(), source)
            self.assert_repeat_stable(base, first)
            MEASUREMENTS.append({"case": "normal", "inputSeconds": 22.5, "recoveredSeconds": first["media"]["durationSeconds"]})

    def test_sigkill_recording_and_paused_loss_at_most_ten_seconds(self):
        for state, milliseconds in [("recording", 14700), ("recording", 22500), ("paused", 22500)]:
            with self.subTest(state=state, milliseconds=milliseconds), self.fixture() as base:
                reached = self.kill_at("seed", base, state, milliseconds)
                accepted = int(reached["acceptedFrames"]) / 48000
                self.assertEqual(accepted, milliseconds / 1000)
                directory = self.session(base)
                source = (directory / SOURCE).read_bytes()
                journal = (directory / JOURNAL).read_bytes()
                recovered = self.invoke("recover", base)
                self.assert_ready(recovered, "interrupted")
                duration = recovered["media"]["durationSeconds"]
                loss = accepted - duration
                self.assertGreaterEqual(loss, -0.08)
                self.assertLessEqual(loss, 10.0, "measured crash loss exceeds the MVP target")
                self.assertEqual((directory / SOURCE).read_bytes(), source)
                self.assertEqual((directory / JOURNAL).read_bytes(), journal)
                self.assert_repeat_stable(base, recovered, "interrupted")
                MEASUREMENTS.append({"case": state, "inputSeconds": accepted, "recoveredSeconds": duration, "lossSeconds": loss})

    def test_sigkill_at_every_durable_checkpoint(self):
        for step in range(1, 9):
            with self.subTest(step=step), self.fixture() as base:
                self.invoke("seed", base, "normal", 2000)
                directory = self.session(base)
                source = (directory / SOURCE).read_bytes()
                journal = (directory / JOURNAL).read_bytes()
                self.kill_at("finalize", base, f"checkpoint:{step}")
                checkpoint = json.loads((directory / CHECKPOINT).read_text())
                self.assertEqual(len(checkpoint["completedSteps"]), step, "must kill after the actual durable step")
                recovered = self.invoke("recover", base)
                self.assert_ready(recovered, steps=8 if step == 8 else 7)
                if step == 8:
                    self.assertFalse((directory / SOURCE).exists(), "explicit proof-gated fixture cleanup already committed")
                else:
                    self.assertEqual((directory / SOURCE).read_bytes(), source)
                self.assertEqual((directory / JOURNAL).read_bytes(), journal)
                self.assert_repeat_stable(base, recovered, steps=8 if step == 8 else 7)
                MEASUREMENTS.append({"case": f"checkpoint:{step}", "recoveryCodes": recovered["recoveryCodes"]})

    def test_sigkill_during_export_and_canonical_publication(self):
        for boundary in ["export", "transcript"]:
            with self.subTest(boundary=boundary), self.fixture() as base:
                self.invoke("seed", base, "normal", 2000)
                directory = self.session(base)
                source = (directory / SOURCE).read_bytes()
                journal = (directory / JOURNAL).read_bytes()
                self.kill_at("finalize", base, boundary)
                recovered = self.invoke("recover", base)
                self.assert_ready(recovered)
                self.assertEqual((directory / SOURCE).read_bytes(), source)
                self.assertEqual((directory / JOURNAL).read_bytes(), journal)
                self.assert_repeat_stable(base, recovered)
                MEASUREMENTS.append({"case": boundary, "recoveryCodes": recovered["recoveryCodes"]})

    def test_sigkill_atomic_write_retains_whole_old_or_new_document(self):
        for boundary in ["beforeWrite", "beforeFlush", "beforeRename", "afterRename"]:
            with self.subTest(boundary=boundary), self.fixture() as base:
                self.kill_at("atomic", base, boundary)
                destination = Path(base) / "document.json"
                self.assertEqual(json.loads(destination.read_text()), {"version": 2 if boundary == "afterRename" else 1})
                MEASUREMENTS.append({"case": "atomic:" + boundary, "version": json.loads(destination.read_text())["version"]})

    def test_sqlite_and_markdown_rebuild_preserves_canonical_and_audio(self):
        with self.fixture() as base:
            self.invoke("seed", base, "normal", 2000)
            first = self.invoke("recover", base)
            self.assert_ready(first)
            directory = self.session(base)
            before = self.hashes(directory)
            database = Path(first["catalogPath"]).resolve()
            self.assertTrue(database.is_relative_to(Path(base).resolve()))
            self.assertTrue(database.exists())
            for path in [database, Path(str(database) + "-wal"), Path(str(database) + "-shm")]:
                path.unlink(missing_ok=True)
            (directory / "transcript.md").unlink()
            repaired = self.invoke("recover", base)
            self.assert_ready(repaired)
            self.assertEqual(self.hashes(directory), before)
            self.assertTrue(database.exists())
            self.assert_repeat_stable(base, repaired)

    def test_missing_and_corrupt_source_are_diagnosed_and_never_deleted(self):
        for fault in ["missing", "corrupt"]:
            with self.subTest(fault=fault), self.fixture() as base:
                self.invoke("seed", base, "normal", 2000)
                directory = self.session(base)
                source = directory / SOURCE
                if fault == "missing":
                    source.rename(Path(base) / "preserved-source.mov")
                else:
                    source.write_bytes(source.read_bytes()[:80])
                protected = {p: (directory / p).read_bytes() for p in [JOURNAL] + ([SOURCE] if fault == "corrupt" else [])}
                for _ in range(2):
                    report = self.invoke("recover", base)
                    self.assertTrue(report["recoveryCodes"])
                    self.assertNotIn("sessionReady", report["recoveryCodes"])
                    self.assertIsNone(report.get("media"))
                    self.assertTrue(directory.exists())
                    for path, data in protected.items():
                        self.assertEqual((directory / path).read_bytes(), data)

    def test_read_only_root_preserves_source_until_access_is_restored(self):
        with self.fixture() as base:
            self.invoke("seed", base, "normal", 2000)
            directory = self.session(base)
            before = self.hashes(directory)
            paths = [Path(base) / "root"] + list((Path(base) / "root").rglob("*"))
            modes = {path: path.stat().st_mode & 0o777 for path in paths}
            try:
                for path in paths:
                    path.chmod(0o555 if path.is_dir() else 0o444)
                report = self.invoke("recover", base)
                self.assertIn("rootReadOnly", report["recoveryCodes"])
                self.assertEqual(self.hashes(directory), before)
            finally:
                for path, mode in modes.items():
                    path.chmod(mode)
            restored = self.invoke("recover", base)
            self.assert_ready(restored)
            self.assertEqual(hashlib.sha256((directory / SOURCE).read_bytes()).hexdigest(), before[SOURCE])
            self.assert_repeat_stable(base, restored)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--results", required=True, type=Path)
    options, tests = parser.parse_known_args()
    PROBE = options.probe.resolve(strict=True)
    if not os.access(PROBE, os.X_OK):
        parser.error("--probe must be an executable built from this checkout")
    if options.results.resolve().is_relative_to(Path(__file__).resolve().parents[2]):
        parser.error("write generated results outside the repository")
    program = unittest.main(argv=[__file__] + tests, exit=False, verbosity=2)
    options.results.parent.mkdir(parents=True, exist_ok=True)
    summary = {"testsRun": program.result.testsRun,
        "failures": len(program.result.failures), "errors": len(program.result.errors),
        "skipped": len(program.result.skipped), "measurements": MEASUREMENTS}
    options.results.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    raise SystemExit(0 if program.result.wasSuccessful() else 1)
