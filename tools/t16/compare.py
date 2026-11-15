"""Local T16 comparison. No network acquisition or product defaults."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

TOOLS = Path(__file__).resolve().parents[1]
RATE = 16000
WINDOW = 20 * RATE
CANDIDATES = {
    "wk-large": TOOLS / "t14/candidate.json",
    "wk-turbo": TOOLS / "t16/whisperkit-turbo.json",
    "cpp-large": TOOLS / "t15/candidate.json",
    "cpp-turbo": TOOLS / "t16/whispercpp-turbo.json",
}


def read(path):
    return json.loads(path.read_text())


def save(path, obj):
    with path.open("x") as file:
        json.dump(obj, file, ensure_ascii=False, indent=2)
        file.write("\n")


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def windows(pcm):
    frames, remainder = divmod(len(pcm), 4)
    if remainder or frames < 8:
        raise ValueError("invalid Float32 input length")
    result = []
    start = 0
    while start < frames:
        end = min(frames, start + WINDOW)
        # STT requests must round to at least 1 ms. Keep a sub-ms tail in the preceding request.
        if frames - end < 8:
            end = frames
        digest = hashlib.sha256(memoryview(pcm)[start * 4:end * 4]).hexdigest()
        result.append(dict(startFrame=start, endFrame=end, sha256=digest))
        start = end
    return result


def prepare(source, start_ms, duration_ms, language, directory):
    source = source.resolve(strict=True)
    if start_ms < 0 or not 1 <= duration_ms <= 900000:
        raise ValueError("expected a nonnegative offset and up to 15 minutes of audio")
    directory.mkdir(mode=0o700)
    stream = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "a:0", "-show_streams", "-of", "json", source,
    ]))["streams"][0]
    channels = stream["channels"]
    mix = "pan=mono|c0<" + "+".join(f"c{i}" for i in range(channels))
    source_hash = file_digest(source)
    raw = directory / "audio.f32"
    args = ["ffmpeg", "-nostdin", "-xerror", "-v", "error", "-n", "-ss", f"{start_ms / 1000:.3f}",
            "-i", str(source), "-map", "0:a:0", "-t", f"{duration_ms / 1000:.3f}", "-af", mix,
            "-ar", str(RATE), "-c:a", "pcm_f32le", "-f", "f32le", str(raw)]
    subprocess.run(args, check=True)
    pcm = raw.read_bytes()
    frames = duration_ms * 16
    if len(pcm) != frames * 4 or source_hash != file_digest(source):
        raise ValueError("source changed or decoded excerpt did not cover the requested duration")
    # The listening copy is derived from precisely the benchmark PCM. The original is also linked.
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-n", "-f", "f32le", "-ar", str(RATE),
                    "-ac", "1", "-i", raw, "-c:a", "pcm_f32le", directory / "listen.wav"], check=True)
    slices = windows(pcm)
    save(directory / "plan.json", dict(schemaVersion=1, source=str(source), sourceSHA256=source_hash,
         sourceStartMs=start_ms, sourceStream=stream, ffmpegVersion=subprocess.check_output(
             ["ffmpeg", "-version"], text=True).splitlines()[0], conversion=args, pcmSHA256=hashlib.sha256(pcm).hexdigest(),
         frameCount=frames, languageMode=language, windows=slices,
         reviewIndices=sorted({0, len(slices) // 2, len(slices) - 1})))


def run_matrix(args):
    root = args.directory.resolve()
    plans = sorted(root.glob("sample-*/plan.json"))
    if not plans or (not args.synthetic and len(plans) < 3):
        raise ValueError("at least three lecture excerpts required")
    stores = dict(zip(CANDIDATES, (args.wk_large, args.turbo, args.cpp_large, args.turbo)))
    intervals = {}
    jobs = []
    for path in plans:
        plan = read(path)
        if not args.synthetic and not 600 * RATE <= plan["frameCount"] <= 900 * RATE:
            raise ValueError("lecture duration outside 10–15 minutes")
        start = plan["sourceStartMs"] * 16
        end = start + plan["frameCount"]
        previous = intervals.setdefault(plan["sourceSHA256"], [])
        if any(a < end and start < b for a, b in previous):
            raise ValueError("overlapping excerpts from one recording")
        previous.append((start, end))
        # Rotate the first candidate across samples to reduce systematic order effects.
        names = list(CANDIDATES)
        shift = (len(jobs) // len(names)) % len(names)
        for name in names[shift:] + names[:shift]:
            jobs.append(dict(sample=path.parent.name, candidate=name, pcmSHA256=plan["pcmSHA256"],
                             checksum=read(CANDIDATES[name])["entries"][0]["model"]["checksum"]))
    save(root / "matrix.json", dict(synthetic=args.synthetic, benchmarkExecutableSHA256=file_digest(args.bin),
         jobs=jobs, repetitions=1, warmupRequests=0,
         retries=0, temperature=0, hints=None, partialResults=True, timestamps=True))
    offline = ["/usr/bin/sandbox-exec", "-f", str(TOOLS / "t14/offline.sb")]
    # Fail closed before any weights or samples are opened. EPERM is an OS denial.
    subprocess.run(offline + ["/usr/bin/python3", "-c",
        "import socket, errno, sys\ntry: socket.socket().connect(('127.0.0.1', 9))\n"
        "except OSError as e: sys.exit(0 if e.errno == errno.EPERM else 1)\nsys.exit(1)"], check=True)
    for job in jobs:
        name, sample = job["candidate"], job["sample"]
        directory = root / sample
        cache = directory / (name + "-cache")
        for subdir in ("home", "cache", "tmp"):
            (cache / subdir).mkdir(parents=True)
        env = dict(os.environ, HOME=str(cache / "home"), CFFIXED_USER_HOME=str(cache / "home"),
                   XDG_CACHE_HOME=str(cache / "cache"), TMPDIR=str(cache / "tmp"))
        with (directory / (name + ".log")).open("x") as log:
            process = subprocess.run(offline + [str(args.bin.resolve()), "lecture", str(CANDIDATES[name]),
                str(stores[name].resolve()), str(directory / "plan.json"), str(directory / name)],
                env=env, stdout=log, stderr=subprocess.STDOUT)
        save(directory / (name + "-exit.json"), dict(returncode=process.returncode))
        print(sample, name, "exit", process.returncode, flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    cmds = parser.add_subparsers(dest="command", required=True)
    prep = cmds.add_parser("prepare")
    prep.add_argument("source", type=Path)
    prep.add_argument("start_ms", type=int)
    prep.add_argument("duration_ms", type=int)
    prep.add_argument("directory", type=Path)
    prep.add_argument("--language", choices=["korean", "english"], default="korean")
    matrix = cmds.add_parser("run")
    for key in ("directory", "bin", "wk_large", "cpp_large", "turbo"):
        matrix.add_argument(key, type=Path)
    matrix.add_argument("--synthetic", action="store_true")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.source, args.start_ms, args.duration_ms, args.language, args.directory)
    else:
        run_matrix(args)
