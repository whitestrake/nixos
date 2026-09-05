#!/usr/bin/env python3
"""Summarise lower-bound fs_usage observations for a Darwin sparsebundle."""

import argparse
import json
from pathlib import Path
import re


BAND = re.compile(r"/bands/([0-9a-f]+)\b", re.IGNORECASE)
BYTES = re.compile(r"\bB=(0x[0-9a-f]+|[0-9]+)\b", re.IGNORECASE)
READ = re.compile(r"\b(?:read|pread|rddata|page[_ -]?in)\b", re.IGNORECASE)
UNAVAILABLE = re.compile(
    r"not permitted|not supported|unsupported|permission denied|failed to",
    re.IGNORECASE,
)


def summarise(trace: str, stderr: str, status: str) -> dict:
    lines = trace.splitlines()
    band_lines = [line for line in lines if BAND.search(line)]
    read_lines = [line for line in band_lines if READ.search(line)]
    read_bytes = 0
    attributed_reads = 0
    for line in read_lines:
        match = BYTES.search(line)
        if match:
            value = match.group(1)
            read_bytes += int(value, 16 if value.lower().startswith("0x") else 10)
            attributed_reads += 1

    unavailable = status.strip() == "unavailable" or (
        not band_lines and bool(UNAVAILABLE.search(stderr))
    )
    return {
        "tracer": "macOS fs_usage",
        "coverageWindow": "sparsebundle attach, Nix installer and nix-fast-build; cache restore excluded",
        "traceState": "unavailable" if unavailable else "observed",
        "traceExitStatus": status.strip() or None,
        "traceBytes": len(trace.encode()),
        "bandPathEvents": len(band_lines),
        "bandReadPathEvents": len(read_lines),
        "uniqueObservedBandPaths": sorted(
            {BAND.search(line).group(1) for line in band_lines}
        ),
        "uniqueObservedReadBands": sorted(
            {BAND.search(line).group(1) for line in read_lines}
        ),
        "attributedReadCalls": attributed_reads,
        "attributedRequestedReadBytes": read_bytes,
        "completeness": {
            "fullBandWorkingSet": False,
            "fullReadBytes": False,
            "classification": "unavailable" if unavailable else "lower-bound",
            "reason": (
                "fs_usage was unavailable on this runner"
                if unavailable
                else "fs_usage can omit pathnames on descriptor and cached reads; only path-attributed events are counted"
            ),
        },
        "stderr": stderr.strip(),
    }


def self_test() -> None:
    result = summarise(
        "12:00:00 pread B=0x1000 /tmp/nix-root.sparsebundle/bands/a diskimagesiod\n"
        "12:00:01 write B=0x20 /tmp/nix-root.sparsebundle/bands/b diskimagesiod\n",
        "",
        "130",
    )
    assert result["uniqueObservedBandPaths"] == ["a", "b"]
    assert result["uniqueObservedReadBands"] == ["a"]
    assert result["attributedReadCalls"] == 1
    assert result["attributedRequestedReadBytes"] == 4096
    assert result["completeness"]["classification"] == "lower-bound"
    assert (
        summarise("", "fs_usage: Operation not permitted", "1")["traceState"]
        == "unavailable"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", nargs="?")
    parser.add_argument("--stderr")
    parser.add_argument("--status")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.trace or not args.stderr or not args.status:
        parser.error("trace, --stderr and --status are required")
    print(
        json.dumps(
            summarise(
                Path(args.trace).read_text(errors="replace")
                if Path(args.trace).exists()
                else "",
                Path(args.stderr).read_text(errors="replace")
                if Path(args.stderr).exists()
                else "",
                Path(args.status).read_text(errors="replace")
                if Path(args.status).exists()
                else "",
            ),
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
