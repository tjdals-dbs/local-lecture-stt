#!/usr/bin/env python3
"""Run local failure cases on new APFS clones of a disposable benchmark store."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(data)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("cli", "store", "input", "output"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    catalog = root / "tools/t15/candidate.json"
    entry = json.loads(catalog.read_text())["entries"][0]["files"][0]
    (original,) = args.store.rglob(entry["path"])
    relative = original.relative_to(args.store)
    args.output.mkdir(mode=0o700)
    for case in ("missing", "truncated", "corrupt"):
        directory = args.output / case
        directory.mkdir()
        clone = directory / "store"
        subprocess.run(["/bin/cp", "-cR", args.store, clone], check=True)
        target = clone / relative
        assert original.stat().st_ino != target.stat().st_ino
        if case == "missing":
            target.rename(directory / "preserved.bin")
        elif case == "truncated":
            with target.open("r+b") as stream:
                stream.truncate(56)
        else:
            with target.open("r+b") as stream:
                stream.seek(-1, 2)
                last = stream.read(1)
                stream.seek(-1, 2)
                stream.write(bytes([last[0] ^ 1]))
        command = ["/usr/bin/sandbox-exec", "-f", root / "tools/t14/offline.sb", args.cli,
                   "run", catalog, clone, args.input, directory / "report", "english"]
        with (directory / "run.log").open("xb") as log:
            status = subprocess.run(command, cwd=directory, stdout=log, stderr=subprocess.STDOUT).returncode
        report = json.loads((directory / "report/report.json").read_text())
        measurement, = report["measurements"]
        assert status == 1 and not report["success"] and measurement["failure"]["code"] == "loadFailed"
        assert "terminal" not in measurement and "inferenceSeconds" not in measurement
        assert (directory / "report/native-0.log").stat().st_size == 0
        assert (directory / "preserved.bin" if case == "missing" else target).exists()
        print(case, status, measurement["failure"]["code"])
    assert digest(original) == entry["sha256"]
    print("Original SHA-256 verified", entry["sha256"])


if __name__ == "__main__":
    main()
