#!/usr/bin/env python3
"""Render the flake.lock package report from binary-cache narinfos.

Head paths come from the CI lane records; base paths are evaluated from the
merge-base checkout. Closures are walked through .narinfo files (NarSize,
References), so no NAR is downloaded, and dix-snapshot diffs them.
"""

import argparse
import http.client
import json
import os
import re
import subprocess
import tempfile
import threading
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from pathlib import Path

import flake_lock_package_report as renderer

# Cachix omits paths that cache.nixos.org already serves, so closures span both.
CACHES = ("cache.nixos.org", "whitestrake.cachix.org")
WORKERS = 32
STORE_NAME = re.compile(r"^[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$")
ATTRIBUTE = re.compile(
    r"^(nixosConfigurations|darwinConfigurations)\.([A-Za-z0-9_-]+)$"
)
PROJECTIONS = {"nixosConfigurations": "linux", "darwinConfigurations": "darwin"}


def store_name(path):
    name = path.removeprefix("/nix/store/")
    if STORE_NAME.fullmatch(name) is None:
        raise ValueError(f"invalid store path: {path!r}")
    return name


class Narinfos:
    """Closure walker with one narinfo memo shared by every host and revision."""

    def __init__(self):
        self.memo = {}
        self.local = threading.local()

    def get(self, host, url):
        connections = self.local.__dict__.setdefault("connections", {})
        for attempt in range(4):
            if host not in connections:
                connections[host] = http.client.HTTPSConnection(host, timeout=30)
            try:
                connections[host].request("GET", url)
                response = connections[host].getresponse()
                body = response.read()
                if response.status < 500:
                    return response.status, body
            except (OSError, http.client.HTTPException):
                connections.pop(host).close()
            time.sleep(0.2 * 2**attempt)
        raise RuntimeError(f"https://{host}{url}: request failed")

    def fetch(self, name):
        for host in CACHES:
            status, body = self.get(host, f"/{name[:32]}.narinfo")
            if status == 404:
                continue
            if status != 200:
                raise RuntimeError(f"https://{host}/{name[:32]}.narinfo: HTTP {status}")
            fields = dict(
                line.split(": ", 1)
                for line in body.decode().splitlines()
                if ": " in line
            )
            if fields.get("StorePath") != f"/nix/store/{name}":
                raise RuntimeError(
                    f"{host} returned a narinfo for another path: {name}"
                )
            refs = fields.get("References", "").split()
            return name, int(fields["NarSize"]), [store_name(ref) for ref in refs]
        raise LookupError(f"narinfo missing from every cache: /nix/store/{name}")

    def snapshot(self, root):
        root = store_name(root)
        seen = {root}
        with ThreadPoolExecutor(WORKERS) as pool:
            pending = set()

            def visit(name):
                if name in self.memo:
                    for ref in self.memo[name][1]:
                        if ref not in seen:
                            seen.add(ref)
                            visit(ref)
                else:
                    pending.add(pool.submit(self.fetch, name))

            visit(root)
            while pending:
                done, pending = wait(pending, return_when=FIRST_COMPLETED)
                for future in done:
                    name, size, refs = future.result()
                    self.memo[name] = (size, refs)
                    for ref in refs:
                        if ref not in seen:
                            seen.add(ref)
                            visit(ref)
        system_path = [
            ref for ref in self.memo[root][1] if ref.endswith("-system-path")
        ]
        if len(system_path) != 1:
            raise LookupError(f"expected one system-path reference: /nix/store/{root}")
        return {
            "closure": sorted(
                [f"/nix/store/{name}", self.memo[name][0]] for name in seen
            ),
            "selected": sorted(
                f"/nix/store/{ref}" for ref in self.memo[system_path[0]][1]
            ),
        }


def evaluate_base(base_dir, attr):
    namespace = attr.split(".")[0]
    result = subprocess.run(
        [
            "nix",
            "eval",
            "--json",
            f".#ci.{PROJECTIONS[namespace]}.{attr}",
            "--apply",
            "d: { path = d.outPath; inherit (d) system; }",
        ],
        cwd=base_dir,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def collect(records, base_dir, dix_snapshot):
    for record in records:
        if ATTRIBUTE.fullmatch(record["attr"]) is None:
            raise ValueError(f"unsafe attribute: {record['attr']!r}")
        store_name(record["storePath"])
    with ThreadPoolExecutor(os.cpu_count()) as pool:
        bases = list(pool.map(lambda r: evaluate_base(base_dir, r["attr"]), records))

    narinfos = Narinfos()
    reports = []
    for record, base in zip(records, bases):
        report = {"name": record["name"], "system": "unknown"}
        if base is None:
            reports.append(report | failed("not evaluable at the merge base"))
            continue
        report["system"] = base["system"]
        if base["path"] == record["storePath"]:
            reports.append(
                report | {"status": "success", "message": "", "diff": {"diffs": []}}
            )
            continue
        started = time.monotonic()
        try:
            snapshots = [
                narinfos.snapshot(base["path"]),
                narinfos.snapshot(record["storePath"]),
            ]
        except LookupError as error:
            print(f"::warning ::{record['name']}: {error}")
            reports.append(
                report | failed("closure metadata missing from binary caches")
            )
            continue
        with tempfile.TemporaryDirectory() as directory:
            files = []
            for index, snapshot in enumerate(snapshots):
                files.append(Path(directory, f"{index}.json"))
                files[-1].write_text(json.dumps(snapshot))
            result = subprocess.run(
                [dix_snapshot, *files], capture_output=True, text=True, check=True
            )
        print(
            f"PACKAGE_REPORT host={record['name']} "
            f"paths={len(snapshots[0]['closure'])}->{len(snapshots[1]['closure'])} "
            f"narinfos={len(narinfos.memo)} seconds={time.monotonic() - started:.2f}"
        )
        reports.append(
            report
            | {"status": "success", "message": "", "diff": json.loads(result.stdout)}
        )
    return reports


def failed(message):
    return {"status": "failed", "message": message, "diff": None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--records", required=True)
    parser.add_argument("--base-dir", required=True)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--dix-snapshot", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    records = json.loads(Path(args.records).read_text())
    reports = collect(records, args.base_dir, args.dix_snapshot)
    Path(args.output).write_text(renderer.render(reports, args.base_sha, args.head_sha))


if __name__ == "__main__":
    main()
