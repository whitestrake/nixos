#!/usr/bin/env python3
"""Pack, publish, and read a block-verified disk image through GitHub Releases."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import socketserver
import struct
import subprocess
import threading
import time
import urllib.error
import urllib.request


SCHEMA = "darwin-release-image-v1"
BLOCK_SIZE = 64 * 1024
SHARD_SIZE = 512 * 1024 * 1024
MANIFEST_NAME = "manifest.json"
DRAFT_NAME = "draft-manifest.json"
HOT_SCHEMA = "darwin-hot-pack-v1"
HOT_MAGIC = b"DRHOT1\0\0"
MAX_HOT_HEADER = 16 * 1024 * 1024


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def file_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while data := stream.read(1024 * 1024):
            digest.update(data)
    return digest.hexdigest()


def is_sha256(value):
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def require(condition, message):
    if not condition:
        raise ValueError(message)


def pack_image(image, output, shard_size=SHARD_SIZE, block_size=BLOCK_SIZE):
    image = Path(image)
    output = Path(output)
    image_bytes = image.stat().st_size
    assert image_bytes > 0 and shard_size > 0 and block_size > 0
    assert shard_size % block_size == 0
    output.mkdir(parents=True, exist_ok=False)
    image_digest = file_sha256(image)
    shards = []
    offset = 0
    with image.open("rb") as source:
        while offset < image_bytes:
            index = len(shards)
            name = f"image-{image_digest[:16]}-{index:05d}.bin"
            path = output / name
            shard_digest = hashlib.sha256()
            blocks = []
            shard_bytes = 0
            with path.open("wb") as target:
                while shard_bytes < shard_size and offset + shard_bytes < image_bytes:
                    size = min(
                        block_size,
                        shard_size - shard_bytes,
                        image_bytes - offset - shard_bytes,
                    )
                    data = source.read(size)
                    assert len(data) == size
                    target.write(data)
                    shard_digest.update(data)
                    blocks.append(
                        {
                            "offset": offset + shard_bytes,
                            "size": size,
                            "sha256": sha256(data),
                        }
                    )
                    shard_bytes += size
            shards.append(
                {
                    "name": name,
                    "offset": offset,
                    "size": shard_bytes,
                    "sha256": shard_digest.hexdigest(),
                    "blocks": blocks,
                }
            )
            offset += shard_bytes
    manifest = {
        "schema": SCHEMA,
        "imageName": image.name,
        "imageBytes": image_bytes,
        "imageSha256": image_digest,
        "blockSize": block_size,
        "shardSize": shard_size,
        "shards": shards,
    }
    validate_manifest(manifest, require_assets=False)
    (output / DRAFT_NAME).write_text(json.dumps(manifest, indent=2) + "\n")
    return {
        "schema": SCHEMA,
        "imageBytes": image_bytes,
        "imageSha256": image_digest,
        "shardCount": len(shards),
        "blockSize": block_size,
        "shardSize": shard_size,
    }


def validate_manifest(manifest, require_assets=True):
    require(manifest.get("schema") == SCHEMA, "invalid manifest schema")
    require(
        isinstance(manifest.get("imageBytes"), int) and manifest["imageBytes"] > 0,
        "invalid image size",
    )
    require(is_sha256(manifest.get("imageSha256")), "invalid image digest")
    block_size = manifest.get("blockSize")
    shard_size = manifest.get("shardSize")
    require(isinstance(block_size, int) and block_size > 0, "invalid block size")
    require(
        isinstance(shard_size, int) and shard_size >= block_size,
        "invalid shard size",
    )
    require(shard_size % block_size == 0, "shard size is not block aligned")
    shards = manifest.get("shards")
    require(isinstance(shards, list) and shards, "manifest has no shards")
    if require_assets:
        require(
            isinstance(manifest.get("releaseId"), int) and manifest["releaseId"] > 0,
            "invalid release ID",
        )
    image_offset = 0
    asset_ids = set()
    for shard_index, shard in enumerate(shards):
        require(shard.get("offset") == image_offset, "non-contiguous shard offset")
        require(
            isinstance(shard.get("size"), int) and 0 < shard["size"] <= shard_size,
            "invalid shard size",
        )
        require(
            shard_index == len(shards) - 1 or shard["size"] == shard_size,
            "short non-final shard",
        )
        require(
            Path(shard.get("name", "")).name == shard.get("name"),
            "invalid shard name",
        )
        require(is_sha256(shard.get("sha256")), "invalid shard digest")
        if require_assets:
            asset_id = shard.get("assetId")
            require(
                isinstance(asset_id, int)
                and asset_id > 0
                and asset_id not in asset_ids,
                "invalid or duplicate asset ID",
            )
            asset_ids.add(asset_id)
        blocks = shard.get("blocks")
        require(isinstance(blocks, list) and blocks, "shard has no blocks")
        block_offset = image_offset
        for block_index, block in enumerate(blocks):
            require(block.get("offset") == block_offset, "non-contiguous block offset")
            require(
                isinstance(block.get("size"), int) and 0 < block["size"] <= block_size,
                "invalid block size",
            )
            require(
                block_index == len(blocks) - 1 or block["size"] == block_size,
                "short non-final block",
            )
            require(is_sha256(block.get("sha256")), "invalid block digest")
            block_offset += block["size"]
        require(
            block_offset == image_offset + shard["size"],
            "block sizes do not match shard size",
        )
        image_offset += shard["size"]
    require(image_offset == manifest["imageBytes"], "shards do not match image size")


def pack_hot(image, manifest_path, profile, output):
    image = Path(image)
    manifest = json.loads(Path(manifest_path).read_text())
    validate_manifest(manifest)
    require(image.stat().st_size == manifest["imageBytes"], "image size mismatch")
    require(file_sha256(image) == manifest["imageSha256"], "image digest mismatch")
    shards = {shard["assetId"]: shard for shard in manifest["shards"]}
    selected = set()
    with Path(profile).open() as stream:
        for line in stream:
            record = json.loads(line)
            if not (
                record.get("kind") == 1
                and record.get("status") == 206
                and record.get("valid") == 1
            ):
                continue
            asset_id = record.get("assetId")
            start = record.get("start")
            end = record.get("end")
            require(asset_id in shards, "profile references unknown asset")
            shard = shards[asset_id]
            require(
                isinstance(start, int) and isinstance(end, int),
                "profile range is not numeric",
            )
            require(0 <= start <= end < shard["size"], "invalid profile range")
            first = (shard["offset"] + start) // manifest["blockSize"]
            last = (shard["offset"] + end) // manifest["blockSize"]
            selected.update(range(first, last + 1))
    blocks = [block for shard in manifest["shards"] for block in shard["blocks"]]
    indices = sorted(selected)
    require(indices and indices[-1] < len(blocks), "profile selects no valid blocks")
    payload_bytes = sum(blocks[index]["size"] for index in indices)
    require(
        0 < payload_bytes <= manifest["imageBytes"],
        "invalid hot-pack payload size",
    )
    header = json.dumps(
        {
            "schema": HOT_SCHEMA,
            "imageSha256": manifest["imageSha256"],
            "blockSize": manifest["blockSize"],
            "blocks": indices,
            "payloadBytes": payload_bytes,
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    require(len(header) <= MAX_HOT_HEADER, "hot-pack header is too large")
    output = Path(output)
    require(not output.exists(), "hot-pack output already exists")
    temporary = output.with_suffix(output.suffix + ".tmp")
    with image.open("rb") as source, temporary.open("xb") as target:
        target.write(HOT_MAGIC)
        target.write(struct.pack(">I", len(header)))
        target.write(header)
        for index in indices:
            block = blocks[index]
            source.seek(block["offset"])
            data = source.read(block["size"])
            require(
                len(data) == block["size"] and sha256(data) == block["sha256"],
                "source block digest mismatch",
            )
            target.write(data)
    os.replace(temporary, output)
    return {
        "schema": HOT_SCHEMA,
        "imageSha256": manifest["imageSha256"],
        "blockSize": manifest["blockSize"],
        "blockCount": len(indices),
        "payloadBytes": payload_bytes,
        "hotPackSha256": file_sha256(output),
    }


def import_hot_pack(path, store):
    path = Path(path)
    with path.open("rb") as stream:
        require(stream.read(len(HOT_MAGIC)) == HOT_MAGIC, "invalid hot-pack magic")
        encoded_length = stream.read(4)
        require(len(encoded_length) == 4, "truncated hot-pack header length")
        header_length = struct.unpack(">I", encoded_length)[0]
        require(0 < header_length <= MAX_HOT_HEADER, "invalid hot-pack header size")
        encoded_header = stream.read(header_length)
        require(len(encoded_header) == header_length, "truncated hot-pack header")
        header = json.loads(encoded_header)
        require(header.get("schema") == HOT_SCHEMA, "invalid hot-pack schema")
        require(
            header.get("imageSha256") == store.manifest["imageSha256"],
            "hot-pack image digest mismatch",
        )
        require(
            header.get("blockSize") == store.manifest["blockSize"],
            "hot-pack block size mismatch",
        )
        indices = header.get("blocks")
        require(isinstance(indices, list) and indices, "hot-pack has no blocks")
        require(indices == sorted(set(indices)), "hot-pack blocks are not unique")
        require(
            all(
                isinstance(index, int) and 0 <= index < len(store.blocks)
                for index in indices
            ),
            "hot-pack block index is out of range",
        )
        payload_bytes = sum(store.blocks[index][1]["size"] for index in indices)
        require(
            header.get("payloadBytes") == payload_bytes,
            "hot-pack payload size mismatch",
        )
        payload_offset = len(HOT_MAGIC) + 4 + header_length
        require(
            path.stat().st_size == payload_offset + payload_bytes,
            "hot-pack file size mismatch",
        )
        for index in indices:
            block = store.blocks[index][1]
            data = stream.read(block["size"])
            require(
                len(data) == block["size"] and sha256(data) == block["sha256"],
                "hot-pack block digest mismatch",
            )
        require(stream.read(1) == b"", "hot-pack has trailing data")
        stream.seek(payload_offset)
        with store.lock:
            for index in indices:
                block = store.blocks[index][1]
                data = stream.read(block["size"])
                require(
                    len(data) == block["size"] and sha256(data) == block["sha256"],
                    "hot-pack block changed during import",
                )
                path = store._path(index)
                temporary = path.with_suffix(".tmp")
                temporary.write_bytes(data)
                os.replace(temporary, path)
    return len(indices), payload_bytes


def gh_api(repo, endpoint, method="GET", payload=None):
    args = ["gh", "api", f"repos/{repo}/{endpoint}"]
    if method != "GET":
        args += ["--method", method]
    if payload is not None:
        args += ["--input", "-"]
    result = subprocess.run(
        args,
        input=json.dumps(payload).encode() if payload is not None else None,
        stdout=subprocess.PIPE,
        check=True,
        timeout=60,
    )
    return json.loads(result.stdout) if result.stdout.strip() else None


def gh_upload(repo, tag, path):
    subprocess.run(
        ["gh", "release", "upload", tag, str(path), "--repo", repo],
        stdout=subprocess.PIPE,
        check=True,
        timeout=600,
    )


def publish(repo, tag, target, directory):
    directory = Path(directory)
    manifest = json.loads((directory / DRAFT_NAME).read_text())
    validate_manifest(manifest, require_assets=False)
    release = gh_api(
        repo,
        "releases",
        "POST",
        {
            "tag_name": tag,
            "target_commitish": target,
            "name": tag,
            "body": "Complete Nix-store image for PR #158 cache transport experiments. Not selected for production CI.",
            "draft": True,
            "prerelease": False,
            "make_latest": "false",
        },
    )
    for shard in manifest["shards"]:
        path = directory / shard["name"]
        require(
            path.stat().st_size == shard["size"]
            and file_sha256(path) == shard["sha256"],
            "local shard integrity mismatch",
        )
        gh_upload(repo, tag, path)
    release = gh_api(repo, f"releases/{release['id']}")
    assets = {asset["name"]: asset for asset in release["assets"]}
    for shard in manifest["shards"]:
        asset = assets[shard["name"]]
        require(asset["size"] == shard["size"], "uploaded shard size mismatch")
        require(
            asset["digest"] == "sha256:" + shard["sha256"],
            "uploaded shard digest mismatch",
        )
        shard["assetId"] = asset["id"]
    manifest["releaseId"] = release["id"]
    manifest_path = directory / MANIFEST_NAME
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    manifest_sha = file_sha256(manifest_path)
    gh_upload(repo, tag, manifest_path)
    release = gh_api(repo, f"releases/{release['id']}")
    manifest_asset = next(
        asset for asset in release["assets"] if asset["name"] == MANIFEST_NAME
    )
    require(
        manifest_asset["size"] == manifest_path.stat().st_size,
        "uploaded manifest size mismatch",
    )
    require(
        manifest_asset["digest"] == "sha256:" + manifest_sha,
        "uploaded manifest digest mismatch",
    )
    gh_api(
        repo,
        f"releases/{release['id']}",
        "PATCH",
        {"draft": False, "make_latest": "false"},
    )
    return {
        "releaseId": release["id"],
        "tag": tag,
        "manifestAssetId": manifest_asset["id"],
        "manifestSha256": manifest_sha,
        "assetCount": len(manifest["shards"]) + 1,
        "imageBytes": manifest["imageBytes"],
        "imageSha256": manifest["imageSha256"],
    }


def download_whole(asset, limit=64 * 1024 * 1024):
    require(0 < asset["size"] <= limit, "asset exceeds download limit")
    with urllib.request.urlopen(asset["browser_download_url"], timeout=60) as response:
        body = response.read(asset["size"] + 1)
    require(len(body) == asset["size"], "asset size mismatch")
    return body


def load_manifest(repo, release_id, manifest_sha, directory):
    require(
        isinstance(release_id, int) and release_id > 0 and is_sha256(manifest_sha),
        "invalid pinned release or manifest digest",
    )
    release = gh_api(repo, f"releases/{release_id}")
    require(release.get("id") == release_id, "release ID changed")
    manifest_assets = [
        asset
        for asset in release.get("assets", [])
        if asset.get("name") == MANIFEST_NAME
    ]
    require(len(manifest_assets) == 1, "release must contain one manifest")
    manifest_asset = manifest_assets[0]
    require(
        manifest_asset.get("id") is not None
        and manifest_asset.get("digest") == "sha256:" + manifest_sha,
        "manifest asset identity mismatch",
    )
    body = download_whole(manifest_asset)
    require(sha256(body) == manifest_sha, "manifest digest mismatch")
    manifest = json.loads(body)
    validate_manifest(manifest)
    require(manifest["releaseId"] == release_id, "manifest release ID mismatch")
    assets = {asset["id"]: asset for asset in release["assets"]}
    for shard in manifest["shards"]:
        asset = assets.get(shard["assetId"])
        require(asset is not None, "pinned shard asset is missing")
        require(asset.get("name") == shard["name"], "shard asset name mismatch")
        require(asset.get("size") == shard["size"], "shard asset size mismatch")
        require(
            asset.get("digest") == "sha256:" + shard["sha256"],
            "shard asset digest mismatch",
        )
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=False)
    (directory / MANIFEST_NAME).write_bytes(body)
    return manifest, assets


class WireLog:
    def __init__(self, path=None):
        self.path = Path(path) if path else None
        self.lock = threading.Lock()
        if self.path:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text("")

    def write(self, record):
        if not self.path:
            return
        assert all(isinstance(value, (int, float)) for value in record.values())
        with self.lock, self.path.open("a") as stream:
            print(json.dumps(record, separators=(",", ":")), file=stream)


class RangeFetcher:
    def __init__(self, repo, assets, wire_log=None, api_call=gh_api):
        self.repo = repo
        self.assets = assets
        self.urls = {
            asset_id: asset["browser_download_url"]
            for asset_id, asset in assets.items()
        }
        self.wire_log = wire_log or WireLog()
        self.api_call = api_call
        self.records = []
        self.lock = threading.Lock()

    def _record(self, asset_id, start, end, status, size, started, refreshed, valid):
        record = {
            "kind": 1,
            "assetId": asset_id,
            "start": start,
            "end": end,
            "status": status,
            "bytes": size,
            "elapsedNs": time.monotonic_ns() - started,
            "refreshed": refreshed,
            "valid": valid,
        }
        with self.lock:
            self.records.append(record)
        self.wire_log.write(record)
        return record

    def _fetch(self, asset_id, start, end, target=None):
        asset = self.assets.get(asset_id)
        require(asset is not None, "unknown pinned asset ID")
        require(0 <= start <= end < asset["size"], "invalid asset byte range")
        refreshed = 0
        for attempt in range(2):
            started = time.monotonic_ns()
            request = urllib.request.Request(
                self.urls[asset_id], headers={"Range": f"bytes={start}-{end}"}
            )
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    expected = end - start + 1
                    if target is None:
                        body = response.read(expected + 1)
                        size = len(body)
                    else:
                        size = 0
                        with Path(target).open("xb") as stream:
                            while chunk := response.read(
                                min(1024 * 1024, expected - size + 1)
                            ):
                                stream.write(chunk)
                                size += len(chunk)
                    status = response.status
                    content_range = response.headers.get("Content-Range")
                    content_length = response.headers.get("Content-Length")
                    final_url = response.geturl()
                valid = int(
                    status == 206
                    and content_range == f"bytes {start}-{end}/{asset['size']}"
                    and content_length == str(expected)
                    and size == expected
                )
                record = self._record(
                    asset_id,
                    start,
                    end,
                    status,
                    size,
                    started,
                    refreshed,
                    valid,
                )
                if not valid:
                    if target is not None:
                        Path(target).unlink(missing_ok=True)
                    raise ValueError(f"invalid range response: {record}")
                self.urls[asset_id] = final_url
                return body if target is None else size
            except urllib.error.HTTPError as error:
                self._record(asset_id, start, end, error.code, 0, started, refreshed, 0)
                if error.code not in (401, 403, 618) or attempt:
                    raise
                fresh = self.api_call(self.repo, f"releases/assets/{asset_id}")
                require(fresh.get("id") == asset_id, "refreshed asset ID mismatch")
                require(
                    fresh.get("name") == asset["name"],
                    "refreshed asset name mismatch",
                )
                require(
                    fresh.get("size") == asset["size"],
                    "refreshed asset size mismatch",
                )
                require(
                    fresh.get("digest") == asset["digest"],
                    "refreshed asset digest mismatch",
                )
                self.assets[asset_id] = fresh
                asset = fresh
                self.urls[asset_id] = fresh["browser_download_url"]
                refreshed = 1
            except urllib.error.URLError:
                self._record(asset_id, start, end, 0, 0, started, refreshed, 0)
                raise
        raise AssertionError("unreachable")

    def fetch(self, asset_id, start, end):
        return self._fetch(asset_id, start, end)

    def fetch_to(self, asset_id, start, end, target):
        return self._fetch(asset_id, start, end, target)

    def summary(self):
        with self.lock:
            records = list(self.records)
        intervals = {}
        for record in records:
            if record["status"] != 206:
                continue
            intervals.setdefault(record["assetId"], []).append(
                (record["start"], record["end"])
            )
        unique = 0
        for ranges in intervals.values():
            merged = []
            for start, end in sorted(ranges):
                if merged and start <= merged[-1][1] + 1:
                    merged[-1][1] = max(merged[-1][1], end)
                else:
                    merged.append([start, end])
            unique += sum(end - start + 1 for start, end in merged)
        return {
            "requestCount": len(records),
            "responseBytes": sum(record["bytes"] for record in records),
            "uniqueResponseBytes": unique,
        }


class BlockStore:
    def __init__(self, repo, release_id, manifest, assets, directory, wire_log=None):
        validate_manifest(manifest)
        require(manifest["releaseId"] == release_id, "manifest release ID mismatch")
        self.manifest = manifest
        self.directory = Path(directory)
        self.cache = self.directory / "blocks"
        self.cache.mkdir(parents=True, exist_ok=True)
        self.fetcher = RangeFetcher(repo, assets, wire_log)
        self.blocks = []
        for shard in manifest["shards"]:
            require(shard["assetId"] in assets, "pinned shard asset is missing")
            for block in shard["blocks"]:
                self.blocks.append((shard, block))
        # ponytail: one lock coalesces duplicate blocks; use per-block locks if concurrency matters.
        self.lock = threading.Lock()

    def _path(self, index):
        block = self.blocks[index][1]
        return self.cache / f"{index:08d}-{block['sha256']}.block"

    def _cached(self, index):
        block = self.blocks[index][1]
        path = self._path(index)
        if not path.exists():
            return None
        data = path.read_bytes()
        if len(data) == block["size"] and sha256(data) == block["sha256"]:
            return data
        path.unlink()
        return None

    def _fetch_group(self, indices, data_by_index):
        shard, first = self.blocks[indices[0]]
        last = self.blocks[indices[-1]][1]
        start = first["offset"] - shard["offset"]
        end = last["offset"] - shard["offset"] + last["size"] - 1
        payload = self.fetcher.fetch(shard["assetId"], start, end)
        position = 0
        for index in indices:
            block = self.blocks[index][1]
            data = payload[position : position + block["size"]]
            require(
                len(data) == block["size"] and sha256(data) == block["sha256"],
                "downloaded block digest mismatch",
            )
            path = self._path(index)
            temporary = path.with_suffix(".tmp")
            temporary.write_bytes(data)
            os.replace(temporary, path)
            data_by_index[index] = data
            position += block["size"]
        require(position == len(payload), "range response has trailing data")

    def read(self, start, length):
        require(0 <= start <= self.manifest["imageBytes"], "invalid image offset")
        require(
            0 <= length <= self.manifest["imageBytes"] - start,
            "invalid image read length",
        )
        if not length:
            return b""
        block_size = self.manifest["blockSize"]
        first = start // block_size
        last = (start + length - 1) // block_size
        with self.lock:
            data_by_index = {}
            groups = []
            group = []
            for index in range(first, last + 1):
                cached = self._cached(index)
                if cached is not None:
                    if group:
                        groups.append(group)
                        group = []
                    data_by_index[index] = cached
                    continue
                if group and self.blocks[group[-1]][0] is not self.blocks[index][0]:
                    groups.append(group)
                    group = []
                group.append(index)
            if group:
                groups.append(group)
            for group in groups:
                self._fetch_group(group, data_by_index)
            data = b"".join(data_by_index[index] for index in range(first, last + 1))
        offset = start - self.blocks[first][1]["offset"]
        return data[offset : offset + length]


def eager(repo, release_id, manifest_sha, directory, workers=1):
    require(isinstance(workers, int) and 1 <= workers <= 4, "workers must be 1..4")
    selection_started = time.monotonic()
    manifest, assets = load_manifest(repo, release_id, manifest_sha, directory)
    selection_seconds = time.monotonic() - selection_started
    fetcher = RangeFetcher(repo, assets)
    directory = Path(directory)
    temporary = directory / "image.dmg.tmp"
    image_path = directory / "image.dmg"
    shard_paths = [
        directory / f"image.dmg.{index:05d}.part"
        for index in range(len(manifest["shards"]))
    ]

    def download(item):
        index, shard = item
        path = shard_paths[index]
        fetcher.fetch_to(shard["assetId"], 0, shard["size"] - 1, path)
        require(file_sha256(path) == shard["sha256"], "shard digest mismatch")

    restore_started = time.monotonic()
    try:
        with ThreadPoolExecutor(max_workers=workers) as executor:
            list(executor.map(download, enumerate(manifest["shards"])))
        image_digest = hashlib.sha256()
        with temporary.open("xb") as image:
            for shard, path in zip(manifest["shards"], shard_paths):
                with path.open("rb") as source:
                    for block in shard["blocks"]:
                        part = source.read(block["size"])
                        require(
                            len(part) == block["size"]
                            and sha256(part) == block["sha256"],
                            "shard block digest mismatch",
                        )
                        image.write(part)
                        image_digest.update(part)
                    require(source.read(1) == b"", "shard has trailing data")
        require(
            temporary.stat().st_size == manifest["imageBytes"],
            "assembled image size mismatch",
        )
        require(
            image_digest.hexdigest() == manifest["imageSha256"],
            "assembled image digest mismatch",
        )
        os.replace(temporary, image_path)
        restore_seconds = time.monotonic() - restore_started
    finally:
        temporary.unlink(missing_ok=True)
        for path in shard_paths:
            path.unlink(missing_ok=True)
    return {
        "releaseId": release_id,
        "manifestSha256": manifest_sha,
        "image": str(image_path),
        "imageBytes": manifest["imageBytes"],
        "imageSha256": manifest["imageSha256"],
        "workers": workers,
        "selectionSeconds": selection_seconds,
        "restoreSeconds": restore_seconds,
        **fetcher.summary(),
    }


def eager_single(
    repo,
    release_id,
    manifest_sha,
    directory,
    zstd=False,
    decoded_sha256=None,
    decoded_size=None,
):
    require(
        (
            zstd
            and is_sha256(decoded_sha256)
            and isinstance(decoded_size, int)
            and decoded_size > 0
        )
        or (not zstd and decoded_sha256 is None and decoded_size is None),
        "decoded size and digest are required only with zstd",
    )
    selection_started = time.monotonic()
    manifest, assets = load_manifest(repo, release_id, manifest_sha, directory)
    selection_seconds = time.monotonic() - selection_started
    require(len(manifest["shards"]) == 1, "single eager mode requires one shard")
    shard = manifest["shards"][0]
    require(
        shard["offset"] == 0 and shard["size"] == manifest["imageBytes"],
        "single shard does not cover the encoded image",
    )
    fetcher = RangeFetcher(repo, assets)
    directory = Path(directory)
    image_path = directory / "image.dmg"
    encoded_path = directory / ("image.dmg.encoded.tmp" if zstd else "image.dmg.tmp")
    decoded_path = directory / "image.dmg.tmp" if zstd else None
    restore_started = time.monotonic()
    download_seconds = verification_seconds = decompression_seconds = 0
    try:
        started = time.monotonic()
        fetcher.fetch_to(shard["assetId"], 0, shard["size"] - 1, encoded_path)
        download_seconds = time.monotonic() - started

        started = time.monotonic()
        require(
            encoded_path.stat().st_size == manifest["imageBytes"],
            "encoded image size mismatch",
        )
        encoded_digest = file_sha256(encoded_path)
        require(
            encoded_digest == shard["sha256"]
            and encoded_digest == manifest["imageSha256"],
            "encoded image digest mismatch",
        )
        verification_seconds = time.monotonic() - started

        if zstd:
            started = time.monotonic()
            with decoded_path.open("xb") as output:
                subprocess.run(
                    ["zstd", "-d", "-q", "-c", str(encoded_path)],
                    stdout=output,
                    stderr=subprocess.PIPE,
                    check=True,
                    timeout=600,
                )
            decompression_seconds = time.monotonic() - started
            started = time.monotonic()
            require(
                decoded_path.stat().st_size == decoded_size,
                "decoded image size mismatch",
            )
            require(
                file_sha256(decoded_path) == decoded_sha256,
                "decoded image digest mismatch",
            )
            verification_seconds += time.monotonic() - started
            os.replace(decoded_path, image_path)
            image_bytes, image_digest = decoded_size, decoded_sha256
        else:
            os.replace(encoded_path, image_path)
            image_bytes, image_digest = manifest["imageBytes"], encoded_digest
        restore_seconds = time.monotonic() - restore_started
    finally:
        encoded_path.unlink(missing_ok=True)
        if decoded_path:
            decoded_path.unlink(missing_ok=True)
    return {
        "releaseId": release_id,
        "manifestSha256": manifest_sha,
        "image": str(image_path),
        "imageBytes": image_bytes,
        "imageSha256": image_digest,
        "encodedBytes": manifest["imageBytes"],
        "encodedSha256": manifest["imageSha256"],
        "workers": 1,
        "selectionSeconds": selection_seconds,
        "restoreSeconds": restore_seconds,
        "downloadSeconds": download_seconds,
        "verificationSeconds": verification_seconds,
        "decompressionSeconds": decompression_seconds,
        **fetcher.summary(),
    }


def parse_range(value, size):
    if value is None:
        return None
    if not value.startswith("bytes=") or "," in value:
        raise ValueError
    first, last = value[6:].split("-", 1)
    if first:
        start = int(first)
        end = min(int(last), size - 1) if last else size - 1
    else:
        count = int(last)
        if count <= 0:
            raise ValueError
        start, end = max(0, size - count), size - 1
    if start < 0 or start >= size or end < start:
        raise ValueError
    return start, end


class ImageServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, store, log):
        self.store = store
        self.wire_log = log
        self.interface_requests = 0
        self.interface_ranges = 0
        self.interface_bytes = 0
        self.metrics_lock = threading.Lock()
        super().__init__(("127.0.0.1", 0), ImageHandler)

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address

    def record_interface(self, method, ranged, status, sent, started, client_port):
        with self.metrics_lock:
            self.interface_requests += 1
            self.interface_ranges += ranged
            self.interface_bytes += sent
        finished = time.monotonic_ns()
        self.wire_log.write(
            {
                "kind": 2,
                "method": method,
                "range": ranged,
                "status": status,
                "bytes": sent,
                "clientPort": client_port,
                "startedNs": started,
                "finishedNs": finished,
                "elapsedNs": finished - started,
            }
        )


class ImageHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_HEAD(self):
        self.respond(False)

    def do_GET(self):
        self.respond(True)

    def respond(self, send_body):
        started = time.monotonic_ns()
        size = self.server.store.manifest["imageBytes"]
        ranged = int(self.headers.get("Range") is not None)
        status, start, end = 200, 0, size - 1
        if self.path != "/image":
            status, start, end = 404, 0, -1
        else:
            try:
                parsed = parse_range(self.headers.get("Range"), size)
                if parsed:
                    status, (start, end) = 206, parsed
            except (TypeError, ValueError):
                status, start, end = 416, 0, -1
        length = max(0, end - start + 1)
        self.send_response(status)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        elif status == 416:
            self.send_header("Content-Range", f"bytes */{size}")
        self.end_headers()
        sent = 0
        if send_body and status in (200, 206):
            try:
                data = self.server.store.read(start, length)
                self.wfile.write(data)
                sent = len(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
        self.server.record_interface(
            int(send_body), ranged, status, sent, started, self.client_address[1]
        )

    def log_message(self, *_args):
        pass


def make_server(store, log):
    return ImageServer(store, WireLog(log))


def serve(repo, release_id, manifest_sha, directory, ready, log, hot_pack=None):
    manifest, assets = load_manifest(repo, release_id, manifest_sha, directory)
    wire_log = WireLog(log)
    store = BlockStore(repo, release_id, manifest, assets, directory, wire_log)
    hot_blocks, hot_bytes = import_hot_pack(hot_pack, store) if hot_pack else (0, 0)
    server = ImageServer(store, wire_log)
    url = f"http://127.0.0.1:{server.server_port}/image"

    def stop(*_args):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    Path(ready).write_text(url + "\n")
    try:
        server.serve_forever()
    finally:
        server.server_close()
    result = {
        "releaseId": release_id,
        "manifestSha256": manifest_sha,
        "image": url,
        "imageBytes": manifest["imageBytes"],
        "imageSha256": manifest["imageSha256"],
        **store.fetcher.summary(),
        "interfaceBytes": server.interface_bytes,
        "interfaceRequests": server.interface_requests,
        "interfaceRangeRequests": server.interface_ranges,
    }
    if hot_pack:
        result.update(
            {
                "hotPackBlocks": hot_blocks,
                "hotPackBytes": hot_bytes,
                "hotPackSha256": file_sha256(hot_pack),
            }
        )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pack = commands.add_parser("pack")
    pack.add_argument("--image", required=True, type=Path)
    pack.add_argument("--output", required=True, type=Path)
    hot = commands.add_parser("pack-hot")
    hot.add_argument("--image", required=True, type=Path)
    hot.add_argument("--manifest", required=True, type=Path)
    hot.add_argument("--profile", required=True, type=Path)
    hot.add_argument("--output", required=True, type=Path)
    publish_parser = commands.add_parser("publish")
    publish_parser.add_argument("--repo", required=True)
    publish_parser.add_argument("--tag", required=True)
    publish_parser.add_argument("--target", required=True)
    publish_parser.add_argument("--directory", required=True, type=Path)
    for name in ("eager", "eager-single", "serve"):
        command = commands.add_parser(name)
        command.add_argument("--repo", required=True)
        command.add_argument("--release-id", required=True, type=int)
        command.add_argument("--manifest-sha", required=True)
        command.add_argument("--directory", required=True, type=Path)
        if name == "eager":
            command.add_argument("--workers", type=int, choices=range(1, 5), default=1)
        if name == "eager-single":
            command.add_argument("--zstd", action="store_true")
            command.add_argument("--decoded-sha256")
            command.add_argument("--decoded-size", type=int)
        if name == "serve":
            command.add_argument("--ready", required=True, type=Path)
            command.add_argument("--log", required=True, type=Path)
            command.add_argument("--hot-pack", type=Path)
    args = parser.parse_args()
    if args.command == "pack":
        result = pack_image(args.image, args.output)
    elif args.command == "pack-hot":
        result = pack_hot(args.image, args.manifest, args.profile, args.output)
    elif args.command == "publish":
        result = publish(args.repo, args.tag, args.target, args.directory)
    elif args.command == "eager":
        result = eager(
            args.repo,
            args.release_id,
            args.manifest_sha,
            args.directory,
            args.workers,
        )
    elif args.command == "eager-single":
        result = eager_single(
            args.repo,
            args.release_id,
            args.manifest_sha,
            args.directory,
            args.zstd,
            args.decoded_sha256,
            args.decoded_size,
        )
    else:
        result = serve(
            args.repo,
            args.release_id,
            args.manifest_sha,
            args.directory,
            args.ready,
            args.log,
            args.hot_pack,
        )
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
