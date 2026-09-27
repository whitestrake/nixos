#!/usr/bin/env python3
"""Temporary one-shot Darwin Nix process diagnostic. Remove after diagnosis."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def probe(name, args, timeout, show=True):
    print(f"CI_NFB_DIAGNOSTIC start={name}", flush=True)
    try:
        process = subprocess.Popen(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            errors="replace",
        )
        try:
            output, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            if process.stdout:
                process.stdout.close()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            print(f"CI_NFB_DIAGNOSTIC {name} timed out", flush=True)
            return None
        print(f"CI_NFB_DIAGNOSTIC {name} exit={process.returncode}", flush=True)
        if show:
            print(output[:100000], flush=True)
        return output if process.returncode == 0 else None
    except OSError as error:
        print(f"CI_NFB_DIAGNOSTIC {name} failed: {error}", flush=True)
    return None


def frame_symbols(report):
    """Return only symbol names, without process headers, paths or arguments."""
    symbols = []
    for line in report.splitlines():
        if " (in " not in line and not re.search(r"\s\+\s\d+\s\(", line):
            continue
        prefix = re.sub(r"^[\s+!|:*\d]+", "", line)
        name = prefix.split(" (in ", 1)[0].split(" + ", 1)[0]
        name = name.split("(", 1)[0].strip()
        if not re.fullmatch(r"[A-Za-z_~][A-Za-z0-9_~:$<>. ]{0,119}", name):
            continue
        if (
            re.search(
                r"wait|sleep|hfs|apfs|vnode|vfs|cluster|disk|block|write|read|open|close|sync|lock|io",
                name,
                re.I,
            )
            and name not in symbols
        ):
            symbols.append(name)
        if len(symbols) == 40:
            break
    return symbols


os.setsid()
time.sleep(480)
# These host probes run independently: a blocked df or process launch cannot
# prevent the process snapshot and kernel-stack attempt.
for name, args in (
    ("vm_stat", ["/usr/bin/vm_stat"]),
    ("iostat", ["/usr/sbin/iostat", "-d", "-c", "1"]),
    ("df_nix", ["/bin/df", "-h", "/nix"]),
    ("df_tmp", ["/bin/df", "-h", "/tmp"]),
):
    try:
        if os.fork() == 0:
            probe(name, args, 10)
            os._exit(0)
    except OSError as error:
        print(f"CI_NFB_DIAGNOSTIC {name} fork failed: {error}", flush=True)
snapshot = probe(
    "ps",
    ["/bin/ps", "-axo", "pid,ppid,stat,wchan,%cpu,time,rss,etime,comm"],
    10,
    show=False,
)
if snapshot:
    names = {"nix", "nix-store", "nix-eval-jobs", "nix-fast-build"}
    rows = [line.split(None, 8) for line in snapshot.splitlines()[1:]]
    print("CI_NFB_DIAGNOSTIC process snapshot\n" + snapshot.splitlines()[0], flush=True)
    host_names = names | {"diskimages-helper", "mdsync", "lsof", "diskutil", "cachix"}
    for line, row in zip(snapshot.splitlines()[1:], rows):
        if len(row) == 9 and (
            row[2].startswith("U") or row[8].rsplit("/", 1)[-1] in host_names
        ):
            print(line, flush=True)
    targets = [
        row
        for row in rows
        if len(row) == 9
        and row[2].startswith("U")
        and row[8].rsplit("/", 1)[-1] in names
    ]
    if targets:
        pid = targets[0][0]
        with tempfile.TemporaryDirectory(prefix="ci-nfb-diagnostic-") as directory:
            report = Path(directory) / "spindump.txt"
            result = probe(
                "spindump",
                [
                    "/usr/bin/sudo",
                    "-n",
                    "/usr/sbin/spindump",
                    pid,
                    "3",
                    "100",
                    "-onlyTarget",
                    "-onlyBlocked",
                    "-noBinary",
                    "-timelimit",
                    "10",
                    "-o",
                    str(report),
                ],
                15,
                show=False,
            )
            if result is not None:
                try:
                    content = report.read_text(errors="replace")
                except PermissionError:
                    content = probe(
                        "spindump_read",
                        ["/usr/bin/sudo", "-n", "/bin/cat", str(report)],
                        10,
                        show=False,
                    )
                except OSError:
                    content = None
                    print("CI_NFB_DIAGNOSTIC spindump report unavailable", flush=True)
                for symbol in frame_symbols(content or ""):
                    print(f"CI_NFB_DIAGNOSTIC waitFrame={symbol}", flush=True)
