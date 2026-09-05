#!/usr/bin/env python3
"""Disposable round-trip measurements for two real evaluator seed generations."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
metrics = {}


def run(label, args):
    started = time.monotonic()
    subprocess.run(args, check=True)
    metrics[label] = time.monotonic() - started


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(path):
    return {
        str(p.relative_to(path)): p.stat().st_size
        for p in path.rglob("*")
        if p.is_file()
    }


base, new = out / "base.erofs", out / "new.erofs"
run(
    "fullCompressSeconds",
    ["zstd", "-q", "-3", "-T0", str(new), "-o", str(out / "full.zst")],
)
run(
    "patchCompressSeconds",
    [
        "zstd",
        "-q",
        "-3",
        "-T0",
        "--patch-from=" + str(base),
        str(new),
        "-o",
        str(out / "patch.zst"),
    ],
)
run(
    "patchRestoreSeconds",
    [
        "zstd",
        "-q",
        "-d",
        "-M1G",
        "--patch-from=" + str(base),
        str(out / "patch.zst"),
        "-o",
        str(out / "patched.erofs"),
    ],
)
assert digest(out / "patched.erofs") == digest(new)
run(
    "fullRestoreSeconds",
    ["zstd", "-q", "-d", str(out / "full.zst"), "-o", str(out / "full.erofs")],
)
assert digest(out / "full.erofs") == digest(new)
store = out / "chunks"
for name in ["base", "new"]:
    run(
        name + "CasyncSeconds",
        [
            "casync",
            "--compression=zstd",
            "--chunk-size=1M",
            "--store=" + str(store),
            "make",
            str(out / (name + ".caibx")),
            str(out / (name + ".erofs")),
        ],
    )
    (out / (name + "-chunks.json")).write_text(
        json.dumps(inventory(store), indent=2) + "\n"
    )
run(
    "casyncRestoreSeconds",
    [
        "casync",
        "--store=" + str(store),
        "extract",
        str(out / "new.caibx"),
        str(out / "restored.erofs"),
    ],
)
assert digest(out / "restored.erofs") == digest(new)
before = json.loads((out / "base-chunks.json").read_text())
after = inventory(store)
metrics.update(
    baseBytes=base.stat().st_size,
    newBytes=new.stat().st_size,
    fullBytes=(out / "full.zst").stat().st_size,
    patchBytes=(out / "patch.zst").stat().st_size,
    oldChunkBytes=sum(before.values()),
    addedChunkBytes=sum(v for k, v in after.items() if k not in before),
    oldChunks=len(before),
    addedChunks=len(set(after) - set(before)),
    baseSha256=digest(base),
    newSha256=digest(new),
    roundTripsVerified=True,
)
(out / "comparison.json").write_text(json.dumps(metrics, indent=2) + "\n")
print(json.dumps(metrics, indent=2))
