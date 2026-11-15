"""Check the unsigned arm64 Release build produced by the product scheme."""
import json
from pathlib import Path
import subprocess
import sys


def verify(app):
    contents = app / "Contents"
    executable = contents / "MacOS/LocalLectureSTT"
    frameworks = contents / "Frameworks"
    libraries = subprocess.check_output(["otool", "-L", executable], text=True)
    symbols = subprocess.check_output(["nm", "-j", executable], text=True)
    if "@rpath/whisper.framework/" not in libraries or not (frameworks / "whisper.framework/whisper").is_file():
        raise ValueError("Missing product whisper.cpp framework or runtime linkage")
    names = "\n".join(p.name for p in contents.rglob("*"))
    for marker in ("WhisperKit", "ArgmaxCore", "FakeSTTEngine"):
        if marker in libraries or marker in symbols or marker in names:
            raise ValueError(f"Development dependency found in the product: {marker}")
    if not symbols.strip() or (contents / "PlugIns").exists():
        raise ValueError("Expected a symbol-bearing Release build without test bundles")
    catalog = contents / "Resources/model-catalog.json"
    candidate = Path(__file__).resolve().parent / "t15/candidate.json"
    if json.loads(catalog.read_bytes()) != json.loads(candidate.read_bytes()):
        raise ValueError("Product catalog differs from the selected T16 candidate")
    print("Verified native engine linkage, bundle contents and pinned product catalog.")


if __name__ == "__main__":
    verify(Path(sys.argv[1]))
