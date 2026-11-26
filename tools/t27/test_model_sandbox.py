"""Real production repositories under OS-enforced ancestor read/create denial."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

PROBE = None


class ModelSandboxTests(unittest.TestCase):
    def run_case(self, mode):
        with tempfile.TemporaryDirectory(prefix="T27-Model-", dir="/private/tmp") as name:
            base = Path(name)
            seed = subprocess.run([str(PROBE), "model-sandbox-probe", "seed", name], capture_output=True, text=True, timeout=15)
            self.assertEqual(seed.returncode, 0, seed.stderr)
            sources = list((base/"opaque").rglob("*.*"))
            before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
            if mode == "symlink":
                (base/"opaque/link").symlink_to(base/"opaque", target_is_directory=True)
            # The exact ancestor remains searchable, but neither list nor mkdir
            # is allowed. Descendants still have ordinary read/write access.
            denied = ["/private", "/private/tmp", name, str(base/"opaque")]
            literals = " ".join("(literal " + json.dumps(p) + ")" for p in denied)
            profile = "(version 1)(allow default)(deny file-read-data " + literals + ")(deny file-write-create " + literals + ")"
            blocked = subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, "/bin/ls", str(base/"opaque")],
                                     capture_output=True, text=True, timeout=10)
            self.assertNotEqual(blocked.returncode, 0, "profile did not enforce ancestor listing denial")
            result = subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, str(PROBE), "model-sandbox-probe", mode, name],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr[-3000:])
            self.assertEqual(before, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
            if mode == "import":
                self.assertEqual(len(list((base/"opaque/Models").rglob("manifest.json"))), 2)
                self.assertFalse(list((base/"opaque/Models").glob(".operation-*")))
            elif mode == "symlink":
                self.assertFalse((base/"opaque/Models").exists())

    def test_two_model_imports_preserve_sources_and_existing_installation(self):
        self.run_case("import")

    def test_diagnostics_create_and_read_below_search_only_ancestors(self):
        self.run_case("diagnostics")

    def test_symlink_ancestor_stays_rejected_and_preserved(self):
        self.run_case("symlink")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", required=True, type=Path)
    args, remaining = parser.parse_known_args()
    PROBE = args.probe.resolve(strict=True)
    unittest.main(argv=[__file__] + remaining, verbosity=2)
