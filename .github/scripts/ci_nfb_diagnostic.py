#!/usr/bin/env python3
"""Temporary one-shot Darwin Nix process snapshot."""

import os
import subprocess
import time

try:
    os.setsid()
    time.sleep(480)
    ps = ["/bin/ps", "-axo", "pid,ppid,stat,etime,comm"]
    snapshot = subprocess.check_output(ps, text=True, timeout=10)
    print("CI_NFB_DIAGNOSTIC process snapshot\n" + snapshot, flush=True)
    names = {"nix", "nix-store", "nix-eval-jobs", "nix-fast-build", "nix-daemon"}
    sampled = 0
    for line in snapshot.splitlines()[1:]:
        fields = line.split(None, 4)
        if len(fields) != 5 or fields[2].startswith("Z"):
            continue
        if fields[4].rsplit("/", 1)[-1] not in names:
            continue
        pid = fields[0]
        try:
            args = ["/usr/bin/sample", pid, "3", "-file", "/dev/stdout"]
            result = subprocess.run(args, capture_output=True, text=True, timeout=15)
            print(
                f"CI_NFB_DIAGNOSTIC samplePid={pid} exit={result.returncode}",
                flush=True,
            )
            print("\n".join(result.stdout.splitlines()[:200]), flush=True)
            if result.returncode:
                print(result.stderr[:300], flush=True)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"CI_NFB_DIAGNOSTIC samplePid={pid} failed: {error}", flush=True)
        sampled += 1
        if sampled == 4:
            break
except (OSError, subprocess.SubprocessError) as error:
    print(f"CI_NFB_DIAGNOSTIC failed: {error}", flush=True)
