#!/usr/bin/env python3
"""Experimental collect-then-build control using the cached NFB toolchain."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


STORE = re.compile(
    r"^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$"
)


def validate_jobs(jobs):
    names = set()
    for job in jobs:
        attr = job.get("attr", "")
        if not re.fullmatch(r"nixosConfigurations\.[A-Za-z0-9_-]+", attr):
            raise ValueError(f"unexpected target: {attr}")
        if attr in names or job.get("error"):
            raise ValueError(f"duplicate or failed evaluation: {attr}")
        names.add(attr)
        drv = job.get("drvPath", "")
        out = job.get("outputs", {}).get("out", "")
        if (
            not STORE.fullmatch(drv)
            or not drv.endswith(".drv")
            or not STORE.fullmatch(out)
        ):
            raise ValueError(f"invalid derivation/output path: {attr}")
    if not jobs:
        raise ValueError("no evaluated targets")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nfb-root", required=True)
    parser.add_argument("--direct-nix")
    parser.add_argument("--eval-cores", type=int, choices=[0, 1], default=1)
    parser.add_argument("--flake", required=True)
    parser.add_argument("--systems", required=True)
    parser.add_argument("--eval-workers", type=int, default=3)
    parser.add_argument("--store", required=True)
    parser.add_argument("--option", nargs=2, action="append", default=[])
    parser.add_argument("--retries", type=int, default=0)
    parser.add_argument("--result-file", required=True)
    parser.add_argument("-j", type=int, default=50)
    parser.add_argument("--stream-json-lines", action="store_true")
    args = parser.parse_args()
    destination = Path(args.result_file)
    evidence = Path(os.environ["RUNNER_TEMP"]) / "measurements"
    results = []

    def event(kind, job, success, duration=0.0):
        row = dict(
            type=kind,
            attr=job["attr"],
            success=success,
            duration=duration,
            outputs=job["outputs"],
            drvPath=job["drvPath"],
        )
        results.append(row)
        print(json.dumps(row), flush=True)

    closure = (
        []
        if args.direct_nix
        else subprocess.check_output(
            ["nix-store", "--query", "--requisites", args.nfb_root], text=True
        ).splitlines()
    )

    def binary(name):
        paths = [
            str(Path(p) / "bin" / name)
            for p in closure
            if (Path(p) / "bin" / name).is_file()
        ]
        if len(paths) != 1:
            raise ValueError(
                f"expected one {name} in cached closure, found {len(paths)}"
            )
        return paths[0]

    evaluator = args.direct_nix or binary("nix-eval-jobs")
    nix = args.direct_nix or binary("nix")
    options = [item for pair in args.option for item in ("--option", *pair)]
    metadata = dict(
        evaluator=evaluator,
        nix=nix,
        nfbRoot=args.nfb_root,
        requestedRetries=args.retries,
        retryPolicy="single batch attempt",
        requestedBuildConcurrency=args.j,
        directEvaluation=bool(args.direct_nix),
        evalCores=args.eval_cores if args.direct_nix else None,
    )
    (evidence / "batch-toolchain.json").write_text(
        json.dumps(metadata, indent=2) + "\n"
    )
    with tempfile.TemporaryDirectory(prefix="batch-eval-") as temporary:
        command = [
            evaluator,
            "--gc-roots-dir",
            temporary,
            "--force-recurse",
            "--max-memory-size",
            "4096",
            "--workers",
            str(args.eval_workers),
            *options,
            "--flake",
            args.flake,
        ]
        if args.direct_nix:
            command = [
                nix,
                "eval",
                "--json",
                args.flake + ".nixosConfigurations",
                "--apply",
                "hosts: builtins.mapAttrs (_: drv: { inherit (drv) drvPath outPath system; }) hosts",
                "--drv-link",
                temporary + "/derivations",
                "--option",
                "extra-experimental-features",
                "parallel-eval",
                "--option",
                "eval-cores",
                str(args.eval_cores),
                *options,
            ]
        (evidence / "batch-eval-command.json").write_text(
            json.dumps(command, indent=2) + "\n"
        )
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
        jobs = []
        try:
            if args.direct_nix:
                raw = json.load(proc.stdout)
                evaluated = (
                    dict(
                        attr="nixosConfigurations." + name,
                        drvPath=row["drvPath"],
                        outputs={"out": row["outPath"]},
                        system=row["system"],
                    )
                    for name, row in raw.items()
                )
            else:
                evaluated = (json.loads(line) for line in proc.stdout)
            for job in evaluated:
                validate_jobs([job])
                if job.get("system") not in args.systems.split():
                    raise ValueError(f"unexpected system for {job['attr']}")
                jobs.append(job)
                event("EVAL", job, True)
            if proc.wait() != 0:
                raise RuntimeError("evaluation failed")
            validate_jobs(jobs)
            (evidence / "batch-evaluations.json").write_text(
                json.dumps(jobs, indent=2) + "\n"
            )
            command = [
                nix,
                "build",
                "--json",
                "--no-link",
                "--keep-going",
                "--eval-store",
                "auto",
                "--store",
                args.store,
                *options,
                *[job["drvPath"] + "^out" for job in jobs],
            ]
            (evidence / "batch-command.json").write_text(
                json.dumps(command, indent=2) + "\n"
            )
            started = time.monotonic()
            build = subprocess.run(command, stdout=subprocess.PIPE, text=True)
            duration = time.monotonic() - started
            (evidence / "batch-build.json").write_text(build.stdout)
            if build.returncode != 0:
                for job in jobs:
                    event("BUILD", job, False, duration)
                return build.returncode
            actual = {
                row["drvPath"]: row["outputs"] for row in json.loads(build.stdout)
            }
            expected = {job["drvPath"]: {"out": job["outputs"]["out"]} for job in jobs}
            if actual != expected:
                raise ValueError("batch returned different derivations or output paths")
            for job in jobs:
                event("BUILD", job, True, duration)
            return 0
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait()
            destination.write_text(json.dumps({"results": results}, indent=2) + "\n")


if __name__ == "__main__":
    sys.exit(main())
