"""Parallel, resumable downloader for hf-mirror (the only reachable model host here).

- splits each file into N byte ranges, one thread each
- per-range .part files, so a killed run resumes where it stopped
- socket timeout + retry loop: a stalled connection cannot hang the whole job
- verifies the final size, then removes the .part files

Usage:
  python dl.py --dest-root <dir> --connections 12 --file <relative-name> <url> [...]
Existing <relative-name>.part0 is treated as the already-downloaded prefix and reused.
"""
import argparse
import os
import sys
import threading
import time
import urllib.request

CHUNK = 1 << 20
TIMEOUT = 25
RETRIES = 40

# The mirror throttles the default "Python-urllib/x.y" user agent down to ~0.35 MB/s.
# Presenting curl's UA measures 4.3+ MB/s on the same URL.
HEADERS = {"User-Agent": "curl/8.4.0", "Accept": "*/*"}


def head_size(url):
    req = urllib.request.Request(url, method="HEAD", headers=HEADERS)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return int(r.headers["Content-Length"])


def fetch_range(url, dest, start, end, label):
    """Download [start, end] inclusive into dest, resuming from dest's current size.

    A sidecar <dest>.range records which byte range the .part file holds. If it does not
    match (e.g. a leftover .part from an earlier run with a different split), the file is
    discarded -- resuming by file size alone silently corrupts the data.
    """
    sidecar = dest + ".range"
    want = f"{start}-{end}"
    have = os.path.getsize(dest) if os.path.exists(dest) else 0
    if have:
        recorded = open(sidecar).read().strip() if os.path.exists(sidecar) else None
        if recorded is None:
            # No sidecar: this can only be a part 0 seeded from an external downloader
            # (we always write sidecars ourselves). Trust it for part 0, distrust anything
            # else, because guessing the range from the file size is what corrupts data.
            if not dest.endswith(".part0"):
                print(f"  [{label}] .part without sidecar -> restarting", flush=True)
                os.remove(dest)
                have = 0
        elif recorded != want:
            print(f"  [{label}] stale .part with range '{recorded}' != '{want}' -> restarting", flush=True)
            os.remove(dest)
            have = 0
    with open(sidecar, "w") as f:
        f.write(want)
    total = end - start + 1
    if have >= total:
        print(f"  [{label}] already complete ({have}/{total})", flush=True)
        return
    attempt = 0
    while have < total and attempt < RETRIES:
        want_start = start + have
        req = urllib.request.Request(url, headers={**HEADERS, "Range": f"bytes={want_start}-{end}"})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                if r.status == 200 and want_start > 0:
                    raise RuntimeError("server ignored Range header")
                mode = "ab" if have else "wb"
                with open(dest, mode) as f:
                    last = time.time()
                    while True:
                        block = r.read(CHUNK)
                        if not block:
                            break
                        f.write(block)
                        have += len(block)
                        last = time.time()
            if have >= total:
                break
        except Exception as e:
            attempt += 1
            have = os.path.getsize(dest) if os.path.exists(dest) else 0
            print(f"  [{label}] retry {attempt}: {type(e).__name__} {e} (have {have}/{total})", flush=True)
            time.sleep(min(2 * attempt, 15))
    print(f"  [{label}] done {have}/{total}", flush=True)


def download(url, dest, connections):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    size = head_size(url)
    if os.path.exists(dest) and os.path.getsize(dest) == size:
        print(f"SKIP {dest} (complete, {size} bytes)", flush=True)
        return True
    print(f"GET  {os.path.basename(dest)}  {size/1048576:.1f} MB  conns={connections}", flush=True)

    prefix_part = dest + ".part0"
    prefix = os.path.getsize(prefix_part) if os.path.exists(prefix_part) else 0
    ranges = []
    if prefix > 0:
        ranges.append((0, prefix - 1))
        print(f"  reusing existing prefix {prefix/1048576:.1f} MB", flush=True)
    remaining_start = prefix
    n = max(1, connections - (1 if prefix > 0 else 0))
    if remaining_start < size:
        span = size - remaining_start
        step = span // n
        for i in range(n):
            s = remaining_start + i * step
            e = size - 1 if i == n - 1 else remaining_start + (i + 1) * step - 1
            ranges.append((s, e))

    threads = []
    for i, (s, e) in enumerate(ranges):
        part = dest + f".part{i}"
        t = threading.Thread(target=fetch_range, args=(url, part, s, e, f"{os.path.basename(dest)}#{i}"), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()

    parts = [dest + f".part{i}" for i in range(len(ranges))]
    for (s, e), p in zip(ranges, parts):
        want = e - s + 1
        got = os.path.getsize(p) if os.path.exists(p) else 0
        if got != want:
            print(f"INCOMPLETE {p} ({got}/{want})", flush=True)
            return False
    tmp = dest + ".merging"
    with open(tmp, "wb") as out:
        for p in parts:
            with open(p, "rb") as f:
                while True:
                    b = f.read(8 << 20)
                    if not b:
                        break
                    out.write(b)
    got = os.path.getsize(tmp)
    if got != size:
        print(f"SIZE MISMATCH {got} != {size}", flush=True)
        os.remove(tmp)
        return False
    os.replace(tmp, dest)
    for p in parts:
        os.remove(p)
        if os.path.exists(p + ".range"):
            os.remove(p + ".range")
    print(f"OK   {dest}  {got/1048576:.1f} MB", flush=True)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest-root", required=True)
    ap.add_argument("--connections", type=int, default=12)
    ap.add_argument("--file", nargs=2, action="append", metavar=("RELNAME", "URL"), required=True)
    args = ap.parse_args()
    for rel, url in args.file:
        dest = os.path.join(args.dest_root, rel.replace("/", os.sep))
        try:
            download(url, dest, args.connections)
        except Exception as e:
            print(f"FAILED {rel}: {type(e).__name__} {e}", flush=True)
    print("ALL DONE", flush=True)


if __name__ == "__main__":
    main()
