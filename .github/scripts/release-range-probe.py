#!/usr/bin/env python3
"""Publish tiny, immutable-by-policy fixtures and test public Release byte ranges."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request


def gh(*args, payload=None):
    env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
    result = subprocess.run(
        ["gh", *args],
        input=json.dumps(payload).encode() if payload is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        check=True,
    )
    return json.loads(result.stdout) if result.stdout.strip() else None


def api(repo, endpoint, payload=None):
    args = ["api", f"repos/{repo}/{endpoint}"]
    if payload is not None:
        args += ["--method", "POST", "--input", "-"]
    return gh(*args, payload=payload)


def patch(repo, release_id, payload):
    return gh(
        "api",
        f"repos/{repo}/releases/{release_id}",
        "--method",
        "PATCH",
        "--input",
        "-",
        payload=payload,
    )


def sha(data):
    return hashlib.sha256(data).hexdigest()


def request_range(asset, spec, expected, records):
    start = time.monotonic()
    upstream = spec
    if spec.startswith("bytes=-"):
        count = min(int(spec.removeprefix("bytes=-")), asset["size"])
        assert count > 0
        upstream = f"bytes={asset['size'] - count}-{asset['size'] - 1}"
    request = urllib.request.Request(
        asset["browser_download_url"], headers={"Range": upstream}
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        # A misbehaving origin must not silently download an unbounded object.
        body = response.read(len(expected) + 1)
        record = {
            "asset_id": asset["id"],
            "range": spec,
            "upstream_range": upstream,
            "status": response.status,
            "content_range": response.headers.get("Content-Range"),
            "content_length": response.headers.get("Content-Length"),
            "bytes_read": len(body),
            "seconds": time.monotonic() - start,
            "matches": body == expected,
            "redirected": response.geturl() != asset["browser_download_url"],
        }
    records.append(record)
    assert record["status"] == 206 and record["matches"], record
    assert (
        record["content_range"]
        == f"bytes {upstream.removeprefix('bytes=')}/{asset['size']}"
    ), record
    return body


def prepare(repo, tag, target, harness, directory):
    directory.mkdir()
    release = api(
        repo,
        "releases",
        {
            "tag_name": tag,
            "target_commitish": target,
            "name": tag,
            "body": "PR #158 synthetic HTTP range and generation-transition fixture. Not a system image.",
            "draft": True,
            "prerelease": False,
            "make_latest": "false",
        },
    )
    parts = []
    offset = 0
    for index, size in enumerate((4 * 1024**2, 4 * 1024**2 + 37)):
        data = os.urandom(size)
        path = directory / f"part-{index}.bin"
        path.write_bytes(data)
        gh("release", "upload", tag, str(path), "--repo", repo)
        parts.append(
            {"name": path.name, "offset": offset, "size": size, "sha256": sha(data)}
        )
        offset += size
    release = api(repo, f"releases/{release['id']}")
    by_name = {asset["name"]: asset for asset in release["assets"]}
    for part in parts:
        asset = by_name[part["name"]]
        assert asset["size"] == part["size"]
        assert asset["digest"] == "sha256:" + part["sha256"]
        part["asset_id"] = asset["id"]
    manifest = {
        "schema": "pr158-synthetic-range-v1",
        "release_id": release["id"],
        "harness": harness,
        "tag_target": target,
        "parts": parts,
        "size": offset,
    }
    path = directory / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    gh("release", "upload", tag, str(path), "--repo", repo)
    release = api(repo, f"releases/{release['id']}")
    assert next(a for a in release["assets"] if a["name"] == path.name)[
        "digest"
    ] == "sha256:" + sha(path.read_bytes())
    return release


def probe(repo, release, directory, records):
    parts = sorted(
        (a for a in release["assets"] if a["name"].startswith("part-")),
        key=lambda a: a["name"],
    )
    for asset in parts:
        data = (directory / asset["name"]).read_bytes()
        request_range(asset, "bytes=0-0", data[:1], records)
        request_range(asset, "bytes=12345-77880", data[12345:77881], records)
        request_range(asset, "bytes=-257", data[-257:], records)
        # Reacquire metadata by pinned asset ID, never via latest.
        refreshed = api(repo, f"releases/assets/{asset['id']}")
        request_range(refreshed, "bytes=42-1065", data[42:1066], records)
    left = (directory / parts[0]["name"]).read_bytes()
    right = (directory / parts[1]["name"]).read_bytes()
    cross = request_range(parts[0], "bytes=-113", left[-113:], records)
    cross += request_range(parts[1], "bytes=0-210", right[:211], records)
    assert cross == left[-113:] + right[:211]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="whitestrake/nixos")
    parser.add_argument("--target", required=True)
    parser.add_argument("--harness", required=True)
    parser.add_argument("--tag-prefix", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    report = {
        "started": time.time(),
        "requests": [],
        "releases": [],
        "expiry_test": "metadata reacquisition only; real elapsed expiry not yet exercised",
    }
    try:
        first = prepare(
            args.repo,
            args.tag_prefix + "-a",
            args.target,
            args.harness,
            args.output / "a",
        )
        report["releases"].append({"id": first["id"], "tag": first["tag_name"]})
        patch(args.repo, first["id"], {"draft": False, "make_latest": "true"})
        pinned = api(args.repo, "releases/latest")
        assert pinned["id"] == first["id"]
        probe(args.repo, pinned, args.output / "a", report["requests"])
        second = prepare(
            args.repo,
            args.tag_prefix + "-b",
            args.target,
            args.harness,
            args.output / "b",
        )
        report["releases"].append({"id": second["id"], "tag": second["tag_name"]})
        assert api(args.repo, "releases/latest")["id"] == first["id"]
        report["draft_did_not_replace_latest"] = True
        patch(args.repo, second["id"], {"draft": False, "make_latest": "true"})
        assert api(args.repo, "releases/latest")["id"] == second["id"]
        probe(args.repo, pinned, args.output / "a", report["requests"])
        report["pinned_predecessor_survived_promotion"] = True
        probe(
            args.repo,
            api(args.repo, "releases/latest"),
            args.output / "b",
            report["requests"],
        )
        report["success"] = True
    finally:
        report["finished"] = time.time()
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(
            json.dumps({k: v for k, v in report.items() if k != "requests"}, indent=2)
        )


if __name__ == "__main__":
    main()
