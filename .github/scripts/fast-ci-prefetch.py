#!/usr/bin/env python3
"""Experimental prefetch of the three large, directly locked input trees."""

from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.parse import urlencode


def reference(locked):
    if locked.get("type") != "github" or locked.get("owner") != "NixOS":
        raise ValueError("expected a directly locked NixOS GitHub input")
    if locked.get("repo") != "nixpkgs" or not re.fullmatch(
        "[0-9a-f]{40}", locked.get("rev", "")
    ):
        raise ValueError("expected a pinned nixpkgs revision")
    if not re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", locked.get("narHash", "")):
        raise ValueError("expected a locked SHA256 NAR hash")
    return (
        "github:NixOS/nixpkgs/"
        + locked["rev"]
        + "?"
        + urlencode({"narHash": locked["narHash"]})
    )


def main():
    output, mode = Path(sys.argv[1]), sys.argv[2]
    if mode not in ("serial", "parallel"):
        raise ValueError("unknown prefetch mode")
    lock = json.loads(Path("flake.lock").read_text())
    root = lock["nodes"][lock["root"]]["inputs"]
    inputs = []
    for name in ("nixpkgs", "nixpkgs-darwin", "nixpkgs-unstable"):
        node = root[name]
        if not isinstance(node, str):
            raise ValueError("expected a direct input, not a follows path")
        locked = lock["nodes"][node]["locked"]
        inputs.append((name, locked, reference(locked)))
    started = time.monotonic()

    def fetch(item):
        name, locked, url = item
        begin = time.monotonic()
        result = json.loads(
            subprocess.check_output(
                ["nix", "flake", "prefetch", "--json", url], text=True
            )
        )
        if result["hash"] != locked["narHash"]:
            raise ValueError("prefetched input hash differs from the lock")
        return dict(name=name, result=result, seconds=time.monotonic() - begin)

    with ThreadPoolExecutor(max_workers=3 if mode == "parallel" else 1) as pool:
        records = list(pool.map(fetch, inputs))
    output.write_text(
        json.dumps(
            dict(mode=mode, seconds=time.monotonic() - started, inputs=records),
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
