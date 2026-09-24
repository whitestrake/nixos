#!/usr/bin/env python3
"""Collect package diffs from successful builds, including a partially failed lane."""

import argparse
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

REPORT_TIMEOUT_SECONDS = 240
CACHE_URL = "https://whitestrake.cachix.org"
STORE_PATH = re.compile(
    r"^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$"
)
REVISION = re.compile(r"^[0-9a-f]{40}$")
ATTRIBUTE = re.compile(
    r"^(nixosConfigurations|darwinConfigurations)\.([A-Za-z0-9_-]+)$"
)


def require_store_path(path):
    if not isinstance(path, str) or STORE_PATH.fullmatch(path) is None:
        raise ValueError(f"invalid store path: {path!r}")
    return path


def write_report(directory, namespace, name, system, base_sha, head_sha, report):
    path = Path(directory) / system / namespace / name / "record.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "name": name,
                "system": system,
                "baseSha": base_sha,
                "headSha": head_sha,
                "packageReport": report,
            }
        )
        + "\n"
    )


def evaluate_base(directory, system, attr):
    result = subprocess.run(
        ["nix", "eval", "--raw", f".#ci.{system}.{attr}.outPath"],
        cwd=directory,
        capture_output=True,
        text=True,
        check=True,
    )
    return require_store_path(result.stdout.strip())


def cache_status(path):
    narinfo = f"{CACHE_URL}/{Path(path).name[:32]}.narinfo"
    try:
        with urllib.request.urlopen(
            urllib.request.Request(narinfo, method="HEAD"), timeout=30
        ) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


def ensure_baseline(path, directory, system=None, attr=None):
    local = subprocess.run(
        ["nix", "path-info", "--recursive", path], capture_output=True, text=True
    )
    if local.returncode == 0:
        return
    if f"error: path '{path}' is not valid" not in local.stderr:
        raise RuntimeError(f"local store check failed: {local.stderr.strip()}")
    status = cache_status(path)
    if status == 200:
        subprocess.run(["nix", "copy", "--from", CACHE_URL, path], check=True)
    elif status == 404:
        result = subprocess.run(
            ["nix", "build", "--no-link", "--print-out-paths", f".#ci.{system}.{attr}"],
            cwd=directory,
            capture_output=True,
            text=True,
            check=True,
        )
        if result.stdout.strip() != path:
            raise ValueError(
                f"baseline build differs from evaluated path: {result.stdout.strip()!r} != {path!r}"
            )
    else:
        raise RuntimeError(f"cache returned {status} for {path}")
    if (
        subprocess.run(
            ["nix", "path-info", "--recursive", path], capture_output=True
        ).returncode
        != 0
    ):
        raise RuntimeError(f"baseline closure is not local: {path}")


def run_dix(base, head):
    result = subprocess.run(
        [os.environ["DIX_BIN"], "--color", "never", "--output", "json", base, head],
        capture_output=True,
        text=True,
        timeout=REPORT_TIMEOUT_SECONDS,
        check=True,
    )
    return json.loads(result.stdout)


def process_journal(journal, base_dir, report_dir, system, base_sha, head_sha):
    if REVISION.fullmatch(base_sha) is None or REVISION.fullmatch(head_sha) is None:
        raise ValueError("invalid comparison revisions")
    events = json.loads(Path(journal).read_text())["events"]
    for event in events:
        if event.get("type") != "BUILD" or event.get("success") is not True:
            continue
        if isinstance(event.get("attr"), str) and event["attr"].startswith("checks."):
            continue
        match = ATTRIBUTE.fullmatch(event.get("attr", ""))
        if match is None:
            raise ValueError(f"unsafe BUILD attribute: {event.get('attr')!r}")
        namespace, name = match.groups()
        head = require_store_path(event.get("outputs", {}).get("out"))
        base = evaluate_base(base_dir, system, event["attr"])
        ensure_baseline(base, base_dir, system, event["attr"])
        try:
            diff = run_dix(base, head)
            report = {"status": "success", "message": "", "diff": diff}
        except (
            OSError,
            ValueError,
            json.JSONDecodeError,
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
        ):
            report = {
                "status": "failed",
                "message": "closure diff failed",
                "diff": None,
            }
        write_report(report_dir, namespace, name, system, base_sha, head_sha, report)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--journal", required=True)
    parser.add_argument("--base-dir", required=True)
    parser.add_argument("--report-dir", required=True)
    parser.add_argument("--system", required=True)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--head-sha", required=True)
    args = parser.parse_args()
    process_journal(
        args.journal,
        args.base_dir,
        args.report_dir,
        args.system,
        args.base_sha,
        args.head_sha,
    )


if __name__ == "__main__":
    main()
