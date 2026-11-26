"""Checks the external observer and build helper without recording or model access."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MONITOR = None
REPO = Path(__file__).resolve().parents[2]


class ValidationToolTests(unittest.TestCase):
    def test_observer_samples_owned_child_without_terminating_it(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            result = subprocess.run([str(MONITOR), str(child.pid), "2", "1"], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = [json.loads(line) for line in result.stdout.splitlines()]
            samples = [row for row in rows if row["kind"] == "sample"]
            self.assertGreaterEqual(len(samples), 3)
            self.assertEqual({row["pid"] for row in samples}, {child.pid})
            self.assertEqual(len({row["processStart"] for row in samples}), 1)
            self.assertTrue(all(row["physicalFootprintBytes"] > 0 for row in samples))
            elapsed = [row["elapsedSeconds"] for row in samples]
            self.assertEqual(elapsed, sorted(elapsed))
            self.assertGreaterEqual(elapsed[-1], 2)
            self.assertEqual(rows[-1]["kind"], "samplingFinished")
            self.assertIsNone(child.poll(), "observer must not stop the target")
        finally:
            child.terminate()
            child.wait(timeout=5)

    def test_invalid_or_unavailable_target_is_not_success(self):
        for args in [["0", "2", "1"], ["1", "nan", "1"], ["1", "2", "0"], ["2147483647", "2", "1"]]:
            with self.subTest(args=args):
                result = subprocess.run([str(MONITOR), *args], capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('"samplingFinished"', result.stdout)

    def test_build_helper_rejects_existing_output_without_modifying_it(self):
        with tempfile.TemporaryDirectory() as root:
            marker = Path(root)/"keep.txt"
            marker.write_text("preserve")
            result = subprocess.run(["bash", str(REPO/"tools/t27/prepare_local_app.sh"), root, root + "-build"],
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(), "preserve")
            self.assertEqual(list(Path(root).iterdir()), [marker])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--monitor", type=Path, required=True)
    options, tests = parser.parse_known_args()
    MONITOR = options.monitor.resolve(strict=True)
    unittest.main(argv=[__file__] + tests, verbosity=2)
