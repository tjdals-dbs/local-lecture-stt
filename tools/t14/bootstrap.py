#!/usr/bin/env python3
"""Explicit developer bootstrap; one pinned candidate, no remote discovery. Runtime never calls this."""
import argparse, concurrent.futures, hashlib, json, pathlib, urllib.request
p = argparse.ArgumentParser(); p.add_argument('destination', type=pathlib.Path); args = p.parse_args()
plan = json.loads(pathlib.Path(__file__).with_name('published-files.json').read_text())
args.destination.mkdir(parents=True, exist_ok=False)
def fetch(f):
    dst = args.destination / f['path']; dst.parent.mkdir(parents=True, exist_ok=True)
    h = hashlib.sha256(); n = 0
    with urllib.request.urlopen(f['httpsURL'], timeout=120) as src, dst.open('xb') as out:
        while chunk := src.read(1024 * 1024):
            out.write(chunk); h.update(chunk); n += len(chunk)
    if n != f['size'] or h.hexdigest() != f['sha256']:
        raise RuntimeError('Pinned payload mismatch: ' + f['path'])
    print(f['path'], n, flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(fetch, plan))
print('Verified source only; install with stt-benchmark import before inference.')
