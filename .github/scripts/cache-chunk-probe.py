#!/usr/bin/env python3
"""Measure fixed-block/native-band reuse without publishing cache objects."""

import hashlib
import json
import pathlib
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor


def chunks(path, size=64 * 1024 * 1024):
    files = sorted(path.rglob("*")) if path.is_dir() else [path]
    for file in files:
        if not file.is_file() or file.is_symlink():
            continue
        with file.open("rb") as stream:
            offset = 0
            while data := stream.read(size):
                yield (
                    str(file.relative_to(path)) if path.is_dir() else "image",
                    offset,
                    data,
                )
                offset += len(data)


def measure(item):
    name, offset, data = item
    compressed = subprocess.run(
        ["zstd", "-q", "-3", "-T1", "-c"],
        input=data,
        stdout=subprocess.PIPE,
        check=True,
    ).stdout
    return dict(
        name=name,
        offset=offset,
        bytes=len(data),
        sha256=hashlib.sha256(data).hexdigest(),
        compressedBytes=len(compressed),
    )


def snapshot(path):
    started = time.monotonic()
    records = []
    # Bound in-flight buffers: Executor.map eagerly submits the whole image.
    with ThreadPoolExecutor(max_workers=2) as pool:
        pending = []
        for item in chunks(path):
            pending.append(pool.submit(measure, item))
            if len(pending) == 2:
                records.extend(f.result() for f in pending)
                pending.clear()
        records.extend(f.result() for f in pending)
    return dict(seconds=time.monotonic() - started, chunks=records)


def compare(old, new):
    known = {r["sha256"] for r in old["chunks"]}
    unique = {r["sha256"]: r for r in new["chunks"]}
    added = [r for digest, r in unique.items() if digest not in known]
    return dict(
        chunks=len(new["chunks"]),
        uniqueChunks=len(unique),
        newUniqueChunks=len(added),
        logicalBytes=sum(r["bytes"] for r in new["chunks"]),
        fullUniqueCompressedBytes=sum(r["compressedBytes"] for r in unique.values()),
        newUniqueCompressedBytes=sum(r["compressedBytes"] for r in added),
    )


if __name__ == "__main__":
    if sys.argv[1] == "compare":
        print(
            json.dumps(
                compare(
                    *(json.loads(pathlib.Path(p).read_text()) for p in sys.argv[2:4])
                ),
                indent=2,
            )
        )
    else:
        print(json.dumps(snapshot(pathlib.Path(sys.argv[1])), indent=2))
