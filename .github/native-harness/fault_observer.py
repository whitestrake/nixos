#!/usr/bin/env python3
"""Kill one recorded Darwin image helper only after a real native read window."""

import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import time


class Inconclusive(RuntimeError):
    pass


def rows():
    output = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pgid=,stat=,command="],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    parsed = []
    for line in output.splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) == 5:
            parsed.append(
                {
                    "pid": int(fields[0]),
                    "ppid": int(fields[1]),
                    "pgid": int(fields[2]),
                    "stat": fields[3],
                    "command": fields[4],
                }
            )
    return parsed


def argv(row):
    try:
        return shlex.split(row["command"])
    except ValueError:
        return []


def descendants(table, ancestor):
    by_pid = {row["pid"]: row for row in table}
    selected = set()
    for row in table:
        pid = row["pid"]
        seen = set()
        while pid in by_pid and pid not in seen:
            if pid == ancestor:
                selected.add(row["pid"])
                break
            seen.add(pid)
            pid = by_pid[pid]["ppid"]
    return selected


def safe_snapshot(table, nfb_pid=None, setup_pid=None):
    roots = [pid for pid in (nfb_pid, setup_pid) if pid]
    selected = set(roots)
    for root in roots:
        selected.update(descendants(table, root))
    result = []
    for row in table:
        if row["pid"] not in selected:
            continue
        clean = dict(row)
        if row["pid"] != nfb_pid:
            clean["command"] = argv(row)[0] if argv(row) else ""
        result.append(clean)
    return result


def matching_nfb(table, executable):
    launcher = Path(executable)
    wrapped = str(launcher.with_name(f".{launcher.name}-wrapped"))
    matches = []
    for row in table:
        args = argv(row)
        identities = [
            candidate
            for candidate in (executable, wrapped)
            if args.count(candidate) == 1
        ]
        if (
            not args
            or len(identities) != 1
            or ".github/scripts/nix_fast_build.py" in args
            or ".github/scripts/ci-nfb.sh" in args
            or row["pid"] != row["pgid"]
        ):
            continue
        if args.count("--flake") == 1:
            index = args.index("--flake")
            if index + 1 < len(args) and args[index + 1] == ".#ci.darwin":
                matches.append(row)
    return matches


def matching_setup(table):
    needles = (
        "/_actions/nixbuild/nix-quick-install-action/",
        "/_actions/cachix/cachix-action/",
    )
    return [row for row in table if any(needle in row["command"] for needle in needles)]


def request_lines(path):
    if not path.exists():
        return []
    return path.read_text(errors="replace").splitlines()


def live_identity(pid, expected_command):
    found = [row for row in rows() if row["pid"] == pid]
    return len(found) == 1 and found[0]["command"] == expected_command, found


def write(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")) + "\n")
    temporary.replace(path)


def freeze_hot_mount(state, expected_release_id):
    mode = json.loads((state / "mode.json").read_text())
    release_id = json.loads((state / "selection.json").read_text())["generation"][
        "releaseId"
    ]
    if mode.get("mode") != "hot" or release_id != expected_release_id:
        raise Inconclusive("pinned hot mount changed before fault")
    return mode, release_id


def observe(args):
    state = Path(args.state)
    evidence = Path(args.evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    requests = state / "reader/requests.jsonl"
    deadline = time.monotonic() + args.timeout
    baseline = None
    subject = None
    observed_ns = None
    first_evaluator = None
    first_cachix = None
    cachix_pids = set()

    while time.monotonic() < deadline:
        table = rows()
        if args.phase == "runtime":
            matches = matching_nfb(table, args.nfb)
        else:
            matches = matching_setup(table) if (state / "mounted").exists() else []
        if len(matches) == 1:
            subject = matches[0]
            observed_ns = time.monotonic_ns()
            baseline = len(request_lines(requests))
            break
        if len(matches) > 1:
            raise Inconclusive(f"multiple {args.phase} process identities")
        time.sleep(0.05)
    if subject is None:
        raise Inconclusive(f"no live {args.phase} process window")

    native = None
    while time.monotonic() < deadline:
        table = rows()
        current = [row for row in table if row["pid"] == subject["pid"]]
        stable = len(current) == 1 and current[0]["command"] == subject["command"]
        if not stable:
            raise Inconclusive(f"{args.phase} process ended before a native read")
        related = descendants(table, subject["pid"])
        for row in table:
            if row["pid"] not in related:
                continue
            if first_evaluator is None and "nix-eval-jobs" in row["command"]:
                first_evaluator = {
                    **row,
                    "command": argv(row)[0] if argv(row) else "nix-eval-jobs",
                }
            if "cachix" in row["command"].lower():
                cachix_pids.add(row["pid"])
                if first_cachix is None:
                    first_cachix = {
                        **row,
                        "command": argv(row)[0] if argv(row) else "cachix",
                    }
        lines = request_lines(requests)
        for line in lines[baseline:]:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (
                record.get("kind") == 2
                and record.get("method") == 1
                and record.get("startedNs", 0) > observed_ns
            ):
                native = record
                break
        if native is not None:
            break
        time.sleep(0.05)
    if native is None:
        raise Inconclusive(
            "no post-start native GET while the observed process was live"
        )

    initial_mode, release_id = freeze_hot_mount(state, args.release_id)
    stable, table = live_identity(subject["pid"], subject["command"])
    if not stable:
        raise Inconclusive(f"{args.phase} identity changed before fault")
    table = rows()
    by_pid = {row["pid"]: row for row in table}
    helper = json.loads((state / "helper.json").read_text())["pid"]
    if helper not in by_pid or by_pid[helper]["stat"].startswith("Z"):
        raise Inconclusive("recorded helper was not live at fault")

    nfb = subject if args.phase == "runtime" else None
    workload = None
    related = set()
    if nfb:
        pid = nfb["ppid"]
        while pid in by_pid:
            row = by_pid[pid]
            command = argv(row)
            if command[:2] == ["/bin/bash", ".github/scripts/ci-nfb.sh"]:
                workload = row
                break
            pid = row["ppid"]
        if workload is None or workload["pid"] != workload["pgid"]:
            raise Inconclusive("ordinary workload session leader was not identifiable")
        nfb_descendants = descendants(table, nfb["pid"])
        related = cachix_pids | {
            row["pid"]
            for row in table
            if row["pid"] in nfb_descendants and "cachix" in row["command"].lower()
        }

    snapshot_root = workload["pid"] if workload is not None else subject["pid"]
    before = safe_snapshot(table, nfb["pid"] if nfb else None, snapshot_root)
    write(evidence / "before-fault.json", before)
    write(evidence / "native-read.json", native)
    write(
        evidence / "process-evidence.json",
        {"firstEvaluator": first_evaluator, "firstCachix": first_cachix},
    )
    os.kill(helper, signal.SIGKILL)
    time.sleep(0.2)
    write(
        evidence / "after-fault.json",
        safe_snapshot(rows(), nfb["pid"] if nfb else None, snapshot_root),
    )
    result = {
        "outcome": "faulted",
        "phase": args.phase,
        "subjectPid": subject["pid"],
        "subjectPgid": subject["pgid"],
        "helperPid": helper,
        "observedNs": observed_ns,
        "requestBaselineLines": baseline,
        "nativeRead": native,
        "initialMode": initial_mode,
        "releaseId": release_id,
    }
    if args.phase == "setup":
        result["setupAction"] = (
            "nix-quick-install"
            if "/_actions/nixbuild/nix-quick-install-action/" in subject["command"]
            else "cachix-action"
        )
    if nfb:
        result.update(
            {
                "nfbPid": nfb["pid"],
                "nfbPgid": nfb["pgid"],
                "workloadPid": workload["pid"],
                "workloadPgid": workload["pgid"],
                "cachixPids": sorted(related),
                "sawEvaluator": first_evaluator is not None,
                "sawCachix": bool(related),
            }
        )
    write(evidence / "observer-result.json", result)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", choices=("runtime", "setup"), required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--release-id", required=True, type=int)
    parser.add_argument("--nfb")
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    if args.phase == "runtime" and not args.nfb:
        parser.error("--nfb is required for runtime observation")
    evidence = Path(args.evidence)
    evidence.mkdir(parents=True, exist_ok=True)
    try:
        observe(args)
    except Inconclusive as error:
        write(
            evidence / "observer-result.json",
            {"outcome": "inconclusive", "reason": str(error)},
        )
        print(f"INCONCLUSIVE: {error}", flush=True)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
