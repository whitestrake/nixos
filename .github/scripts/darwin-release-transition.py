#!/usr/bin/env python3
"""One-shot, fail-closed lifecycle probe for a validated Darwin Release image."""

import argparse
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

SCRIPT = Path(__file__).with_name("darwin-release-image.py")
SPEC = importlib.util.spec_from_file_location("darwin_release_image", SCRIPT)
IMAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMAGE)

PREDECESSOR_RELEASE_ID = 383622742
PREDECESSOR_MANIFEST_SHA = (
    "8406fdfb37a9c2bdfe98195cf1193a02470b1d84d3a1451c78e8248a8fc6d3aa"
)
RELEASE_TARGET_SHA = "aed47803728f84ad1076f48223f143ecb3ccc012"
OWNED_TAG = re.compile(r"pr158-e49-transition-[1-9][0-9]*-[1-9][0-9]*")


def require_latest(release, expected_id):
    assert release["id"] == expected_id
    assert release["draft"] is False and release["prerelease"] is False


def require_owned_tag(tag):
    assert OWNED_TAG.fullmatch(tag)


def require_owned_draft(release, release_id, tag, asset, allow_missing_asset=False):
    assert release["id"] == release_id
    assert release["tag_name"] == tag
    assert release["target_commitish"] == RELEASE_TARGET_SHA
    assert release["draft"] is True and release["prerelease"] is False
    if allow_missing_asset and not release["assets"]:
        return
    assert len(release["assets"]) == 1
    actual = release["assets"][0]
    if "id" in asset:
        assert actual["id"] == asset["id"]
    assert actual["name"] == asset["name"] != IMAGE.MANIFEST_NAME
    assert actual["size"] == asset["size"]
    assert actual["digest"] == asset["digest"]


def require_empty_owned_draft(release, release_id, tag):
    assert release["id"] == release_id
    assert release["tag_name"] == tag
    assert release["target_commitish"] == RELEASE_TARGET_SHA
    assert release["draft"] is True and release["prerelease"] is False
    assert release["assets"] == []


def phase_block_indices(count):
    assert count >= 3
    indices = [0, count // 2, count - 1]
    assert len(set(indices)) == 3
    return indices


def blocks(manifest):
    return [block for shard in manifest["shards"] for block in shard["blocks"]]


def read_local_block(url, manifest, index, phase):
    block = blocks(manifest)[index]
    start = block["offset"]
    end = start + block["size"] - 1
    request = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    started = time.monotonic_ns()
    with urllib.request.urlopen(request, timeout=60) as response:
        body = response.read(block["size"] + 1)
        status = response.status
        content_range = response.headers.get("Content-Range")
        content_length = response.headers.get("Content-Length")
    finished = time.monotonic_ns()
    assert status == 206
    assert content_range == f"bytes {start}-{end}/{manifest['imageBytes']}"
    assert content_length == str(block["size"])
    assert len(body) == block["size"] and IMAGE.sha256(body) == block["sha256"]
    return {
        "phase": phase,
        "blockIndex": index,
        "offset": start,
        "bytes": len(body),
        "sha256": block["sha256"],
        "startedNs": started,
        "finishedNs": finished,
    }


def read_pinned_block(fetcher, manifest, index, phase):
    block_list = blocks(manifest)
    block = block_list[index]
    shard = next(
        shard
        for shard in manifest["shards"]
        if shard["offset"] <= block["offset"] < shard["offset"] + shard["size"]
    )
    start = block["offset"] - shard["offset"]
    data = fetcher.fetch(shard["assetId"], start, start + block["size"] - 1)
    assert IMAGE.sha256(data) == block["sha256"]
    return {
        "phase": phase,
        "blockIndex": index,
        "assetId": shard["assetId"],
        "offset": block["offset"],
        "bytes": len(data),
        "sha256": block["sha256"],
    }


def wait_ready(process, ready, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert process.poll() is None
        if ready.is_file() and ready.stat().st_size:
            return ready.read_text().strip()
        time.sleep(0.1)
    raise TimeoutError("predecessor helper did not become ready")


def stop_helper(process):
    if process.poll() is None:
        process.terminate()
    try:
        stdout, _stderr = process.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, _stderr = process.communicate(timeout=10)
    assert process.returncode == 0
    result = json.loads(stdout)
    assert result["releaseId"] == PREDECESSOR_RELEASE_ID
    assert result["manifestSha256"] == PREDECESSOR_MANIFEST_SHA
    return {key: value for key, value in result.items() if key != "image"}


def exact_tag_ref(repo, tag):
    refs = IMAGE.gh_api(repo, f"git/matching-refs/tags/{tag}")
    exact = [ref for ref in refs if ref["ref"] == f"refs/tags/{tag}"]
    assert len(exact) <= 1
    return exact[0] if exact else None


def require_unused_owned_tag(repo, tag):
    require_owned_tag(tag)
    assert exact_tag_ref(repo, tag) is None


def cleanup_owned_draft(repo, release_id, tag, asset):
    release = IMAGE.gh_api(repo, f"releases/{release_id}")
    require_owned_draft(release, release_id, tag, asset, allow_missing_asset=True)
    tag_ref = exact_tag_ref(repo, tag)
    if tag_ref:
        assert tag_ref["object"]["type"] == "commit"
        assert tag_ref["object"]["sha"] == RELEASE_TARGET_SHA
    if tag_ref:
        IMAGE.gh_api(repo, f"git/refs/tags/{tag}", "DELETE")
    IMAGE.gh_api(repo, f"releases/{release_id}", "DELETE")
    return {
        "releaseDeleted": True,
        "tag": "deleted" if tag_ref is not None else "never-existed",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="whitestrake/nixos")
    parser.add_argument("--successor-release-id", required=True, type=int)
    parser.add_argument("--successor-manifest-sha", required=True)
    parser.add_argument("--owned-tag", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    assert args.successor_release_id > 0
    assert args.successor_release_id != PREDECESSOR_RELEASE_ID
    assert IMAGE.is_sha256(args.successor_manifest_sha)
    require_owned_tag(args.owned_tag)
    args.output.mkdir(parents=True, exist_ok=False)
    report = {
        "schema": "darwin-release-transition-v1",
        "started": time.time(),
        "repo": args.repo,
        "predecessorReleaseId": PREDECESSOR_RELEASE_ID,
        "predecessorManifestSha256": PREDECESSOR_MANIFEST_SHA,
        "successorReleaseId": args.successor_release_id,
        "successorManifestSha256": args.successor_manifest_sha,
        "ownedTag": args.owned_tag,
        "targetCommit": RELEASE_TARGET_SHA,
        "events": [],
        "predecessorReads": [],
        "successorReads": [],
    }
    helper = None
    owned_release_id = None
    owned_asset = None
    helper_result = None
    primary_error = None
    cleanup_error = None
    with tempfile.TemporaryDirectory(prefix="darwin-release-transition-") as temporary:
        temporary = Path(temporary)
        try:
            latest = IMAGE.gh_api(args.repo, "releases/latest")
            require_latest(latest, PREDECESSOR_RELEASE_ID)
            report["events"].append("initial-latest-is-predecessor")

            predecessor, _ = IMAGE.load_manifest(
                args.repo,
                PREDECESSOR_RELEASE_ID,
                PREDECESSOR_MANIFEST_SHA,
                temporary / "predecessor-validation",
            )
            successor_release = IMAGE.gh_api(
                args.repo, f"releases/{args.successor_release_id}"
            )
            require_latest(successor_release, args.successor_release_id)
            successor, successor_assets = IMAGE.load_manifest(
                args.repo,
                args.successor_release_id,
                args.successor_manifest_sha,
                temporary / "successor-validation",
            )
            report["events"].append("both-manifests-and-assets-validated")

            ready = temporary / "predecessor.ready"
            helper = subprocess.Popen(
                [
                    sys.executable,
                    str(SCRIPT),
                    "serve",
                    "--repo",
                    args.repo,
                    "--release-id",
                    str(PREDECESSOR_RELEASE_ID),
                    "--manifest-sha",
                    PREDECESSOR_MANIFEST_SHA,
                    "--directory",
                    str(temporary / "predecessor-server"),
                    "--ready",
                    str(ready),
                    "--log",
                    str(args.output / "predecessor-wire.jsonl"),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            helper_url = wait_ready(helper, ready)
            report["predecessorHelperPid"] = helper.pid
            indices = phase_block_indices(len(blocks(predecessor)))
            report["predecessorReads"].append(
                read_local_block(helper_url, predecessor, indices[0], "before")
            )

            shard = min(successor["shards"], key=lambda item: item["size"])
            fetcher = IMAGE.RangeFetcher(args.repo, successor_assets)
            shard_data = fetcher.fetch(shard["assetId"], 0, shard["size"] - 1)
            assert len(shard_data) == shard["size"]
            assert IMAGE.sha256(shard_data) == shard["sha256"]
            shard_path = temporary / shard["name"]
            shard_path.write_bytes(shard_data)
            del shard_data
            report["sacrificialSourceShard"] = {
                "assetId": shard["assetId"],
                "name": shard["name"],
                "bytes": shard["size"],
                "sha256": shard["sha256"],
                **fetcher.summary(),
            }

            owned_asset = {
                "name": shard["name"],
                "size": shard["size"],
                "digest": "sha256:" + shard["sha256"],
            }
            require_unused_owned_tag(args.repo, args.owned_tag)
            owned_release = IMAGE.gh_api(
                args.repo,
                "releases",
                "POST",
                {
                    "tag_name": args.owned_tag,
                    "target_commitish": RELEASE_TARGET_SHA,
                    "name": args.owned_tag,
                    "body": "PR #158 one-shot Release transition probe. Sacrificial incomplete draft.",
                    "draft": True,
                    "prerelease": False,
                    "make_latest": "false",
                },
            )
            owned_release_id = owned_release["id"]
            require_empty_owned_draft(owned_release, owned_release_id, args.owned_tag)
            IMAGE.gh_upload(args.repo, args.owned_tag, shard_path)
            shard_path.unlink()
            owned_release = IMAGE.gh_api(args.repo, f"releases/{owned_release_id}")
            destination = owned_release["assets"]
            assert len(destination) == 1
            owned_asset = {**owned_asset, "id": destination[0]["id"]}
            require_owned_draft(
                owned_release, owned_release_id, args.owned_tag, owned_asset
            )
            require_latest(
                IMAGE.gh_api(args.repo, "releases/latest"),
                PREDECESSOR_RELEASE_ID,
            )
            report["events"].append("incomplete-draft-did-not-change-latest")
            assert helper.poll() is None
            report["predecessorReads"].append(
                read_local_block(helper_url, predecessor, indices[1], "during")
            )

            report["sacrificialCleanup"] = cleanup_owned_draft(
                args.repo, owned_release_id, args.owned_tag, owned_asset
            )
            owned_release_id = None
            require_latest(
                IMAGE.gh_api(args.repo, "releases/latest"),
                PREDECESSOR_RELEASE_ID,
            )
            report["events"].append("owned-draft-and-tag-cleaned")

            IMAGE.gh_api(
                args.repo,
                f"releases/{args.successor_release_id}",
                "PATCH",
                {"make_latest": "true"},
            )
            latest = IMAGE.gh_api(args.repo, "releases/latest")
            require_latest(latest, args.successor_release_id)
            report["events"].append("successor-promoted-once")

            assert (
                helper.poll() is None and helper.pid == report["predecessorHelperPid"]
            )
            report["predecessorReads"].append(
                read_local_block(helper_url, predecessor, indices[2], "after")
            )
            report["events"].append("same-predecessor-helper-survived-transition")

            fresh_manifest, fresh_assets = IMAGE.load_manifest(
                args.repo,
                latest["id"],
                args.successor_manifest_sha,
                temporary / "fresh-latest-reader",
            )
            fresh_fetcher = IMAGE.RangeFetcher(args.repo, fresh_assets)
            fresh_indices = phase_block_indices(len(blocks(fresh_manifest)))
            for index in fresh_indices:
                report["successorReads"].append(
                    read_pinned_block(
                        fresh_fetcher, fresh_manifest, index, "fresh-latest-pinned"
                    )
                )
            report["freshReader"] = {
                "resolvedLatestReleaseId": latest["id"],
                "pinnedManifestReleaseId": fresh_manifest["releaseId"],
                **fresh_fetcher.summary(),
            }
            report["events"].append(
                "fresh-reader-resolved-once-then-used-pinned-assets"
            )
            report["success"] = True
        except Exception as error:  # noqa: BLE001 - cleanup and safe evidence are mandatory
            primary_error = error
            report["success"] = False
            report["error"] = {"type": type(error).__name__}
        finally:
            if owned_release_id is not None:
                try:
                    report["sacrificialCleanup"] = cleanup_owned_draft(
                        args.repo, owned_release_id, args.owned_tag, owned_asset
                    )
                    owned_release_id = None
                except Exception as error:  # noqa: BLE001 - report cleanup failure
                    cleanup_error = error
                    report["cleanupError"] = {"type": type(error).__name__}
            if helper is not None:
                try:
                    helper_result = stop_helper(helper)
                    report["predecessorHelper"] = helper_result
                except Exception as error:  # noqa: BLE001 - always reap the helper
                    if primary_error is None:
                        primary_error = error
                    report["helperStopError"] = {"type": type(error).__name__}
            report["finished"] = time.time()
            (args.output / "report.json").write_text(
                json.dumps(report, indent=2, sort_keys=True) + "\n"
            )

    if cleanup_error is not None:
        raise RuntimeError(
            f"owned cleanup failed: {type(cleanup_error).__name__}"
        ) from None
    if primary_error is not None:
        raise RuntimeError(
            f"transition failed: {type(primary_error).__name__}"
        ) from None
    print(
        json.dumps(
            {
                "success": True,
                "predecessorReleaseId": PREDECESSOR_RELEASE_ID,
                "successorReleaseId": args.successor_release_id,
                "report": str(args.output / "report.json"),
            },
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
