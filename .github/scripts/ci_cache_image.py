#!/usr/bin/env python3
"""Pack, publish, and read a block-verified disk image through GitHub Releases."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
from pathlib import Path
import signal
import shutil
import socketserver
import struct
import subprocess
import threading
import urllib.error
import urllib.request


SCHEMA = "ci-cache-image-v1"
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
    require(
        image_bytes > 0
        and 0 < block_size <= BLOCK_SIZE
        and block_size <= shard_size <= SHARD_SIZE,
        "invalid pack sizes",
    )
    require(shard_size % block_size == 0, "unaligned shard size")
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
                    require(len(data) == size, "source changed during packing")
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
        type(manifest.get("imageBytes")) is int and manifest["imageBytes"] > 0,
        "invalid image size",
    )
    require(is_sha256(manifest.get("imageSha256")), "invalid image digest")
    if (
        "filesystemGate" in manifest
        or manifest.get("component") == "darwin-image-aarch64-darwin"
    ):
        gate = manifest.get("filesystemGate", {})
        require(
            all(
                gate.get(key) == manifest["imageSha256"]
                for key in ("imageSha256", "imageSha256Before", "imageSha256After")
            )
            and gate.get("fsck") == "fsck_hfs -fn"
            and type(gate.get("fsckStatus")) is int
            and gate["fsckStatus"] == 0,
            "missing exact-image filesystem gate",
        )
    block_size = manifest.get("blockSize")
    shard_size = manifest.get("shardSize")
    require(
        type(block_size) is int and 0 < block_size <= BLOCK_SIZE, "invalid block size"
    )
    require(
        type(shard_size) is int and block_size <= shard_size <= SHARD_SIZE,
        "invalid shard size",
    )
    require(shard_size % block_size == 0, "shard size is not block aligned")
    shards = manifest.get("shards")
    require(isinstance(shards, list) and shards, "manifest has no shards")
    if require_assets:
        require(
            type(manifest.get("releaseId")) is int and manifest["releaseId"] > 0,
            "invalid release ID",
        )
    image_offset = 0
    asset_ids = set()
    for shard_index, shard in enumerate(shards):
        require(
            type(shard.get("offset")) is int and shard["offset"] == image_offset,
            "non-contiguous shard offset",
        )
        require(
            type(shard.get("size")) is int and 0 < shard["size"] <= shard_size,
            "invalid shard size",
        )
        require(
            shard_index == len(shards) - 1 or shard["size"] == shard_size,
            "short non-final shard",
        )
        require(
            isinstance(shard.get("name"), str)
            and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,199}", shard["name"])
            is not None,
            "invalid shard name",
        )
        require(is_sha256(shard.get("sha256")), "invalid shard digest")
        if require_assets:
            asset_id = shard.get("assetId")
            require(
                type(asset_id) is int and asset_id > 0 and asset_id not in asset_ids,
                "invalid or duplicate asset ID",
            )
            asset_ids.add(asset_id)
        blocks = shard.get("blocks")
        require(isinstance(blocks, list) and blocks, "shard has no blocks")
        block_offset = image_offset
        for block_index, block in enumerate(blocks):
            require(
                type(block.get("offset")) is int and block["offset"] == block_offset,
                "non-contiguous block offset",
            )
            require(
                type(block.get("size")) is int and 0 < block["size"] <= block_size,
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
    validate_manifest(manifest, require_assets=False)
    require(image.stat().st_size == manifest["imageBytes"], "image size mismatch")
    require(file_sha256(image) == manifest["imageSha256"], "image digest mismatch")
    blocks = [block for shard in manifest["shards"] for block in shard["blocks"]]
    try:
        indices = sorted({int(line) for line in Path(profile).read_text().splitlines()})
    except ValueError as error:
        raise ValueError("profile contains a non-numeric block index") from error
    require(
        indices and 0 <= indices[0] and indices[-1] < len(blocks),
        "profile selects no valid blocks",
    )
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
    require(
        re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo), "invalid repository"
    )
    args = ["gh", "api", f"repos/{repo}/{endpoint}"]
    if method != "GET":
        args += ["--method", method]
    if payload is not None:
        args += ["--input", "-"]
    result = subprocess.run(
        args,
        input=json.dumps(payload).encode() if payload is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
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


def download_whole(asset, limit=64 * 1024 * 1024):
    require(0 < asset["size"] <= limit, "asset exceeds download limit")
    with urllib.request.urlopen(asset["browser_download_url"], timeout=60) as response:
        body = response.read(asset["size"] + 1)
    require(len(body) == asset["size"], "asset size mismatch")
    return body


def gh_download_whole(repo, asset, limit=64 * 1024 * 1024):
    require(
        re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo),
        "invalid repository",
    )
    require(
        type(asset.get("id")) is int and asset["id"] > 0 and 0 < asset["size"] <= limit,
        "invalid asset or download limit",
    )
    body = subprocess.run(
        [
            "gh",
            "api",
            f"repos/{repo}/releases/assets/{asset['id']}",
            "--header",
            "Accept: application/octet-stream",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
        timeout=60,
    ).stdout
    require(len(body) == asset["size"], "asset size mismatch")
    return body


def load_manifest(repo, release_id, manifest_identity, directory):
    # The identity comes from a frozen, authenticated generation selection.
    require(
        isinstance(manifest_identity, dict), "component manifest identity is required"
    )
    require(
        isinstance(release_id, int)
        and release_id > 0
        and is_sha256(manifest_identity["sha256"]),
        "invalid pinned release or manifest digest",
    )
    release = gh_api(repo, f"releases/{release_id}")
    require(release.get("id") == release_id, "release ID changed")
    manifest_assets = [
        asset
        for asset in release.get("assets", [])
        if asset.get("id") == manifest_identity["assetId"]
        and asset.get("name") == manifest_identity["name"]
        and asset.get("size") == manifest_identity["size"]
    ]
    require(len(manifest_assets) == 1, "release must contain one manifest")
    manifest_asset = manifest_assets[0]
    require(
        manifest_asset.get("id") is not None
        and manifest_asset.get("digest") == "sha256:" + manifest_identity["sha256"],
        "manifest asset identity mismatch",
    )
    body = download_whole(manifest_asset)
    require(sha256(body) == manifest_identity["sha256"], "manifest digest mismatch")
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


class RangeFetcher:
    def __init__(self, repo, assets):
        self.repo = repo
        self.assets = assets
        self.urls = {
            asset_id: asset["browser_download_url"]
            for asset_id, asset in assets.items()
        }

    def _fetch(self, asset_id, start, end, target=None):
        asset = self.assets.get(asset_id)
        require(asset is not None, "unknown pinned asset ID")
        require(0 <= start <= end < asset["size"], "invalid asset byte range")
        for attempt in range(2):
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
                valid = (
                    status == 206
                    and content_range == f"bytes {start}-{end}/{asset['size']}"
                    and content_length == str(expected)
                    and size == expected
                )
                if not valid:
                    if target is not None:
                        Path(target).unlink(missing_ok=True)
                    raise ValueError(
                        "invalid range response: "
                        f"status={status} range={content_range!r} "
                        f"length={content_length!r} bytes={size} expected={expected}"
                    )
                self.urls[asset_id] = final_url
                return body if target is None else size
            except urllib.error.HTTPError as error:
                if error.code not in (401, 403, 618) or attempt:
                    raise
                fresh = gh_api(self.repo, f"releases/assets/{asset_id}")
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
        raise AssertionError("unreachable")

    def fetch(self, asset_id, start, end):
        return self._fetch(asset_id, start, end)

    def fetch_to(self, asset_id, start, end, target):
        return self._fetch(asset_id, start, end, target)


class BlockStore:
    def __init__(
        self,
        repo,
        release_id,
        manifest,
        assets,
        directory,
        local_image=None,
        profile=None,
    ):
        validate_manifest(manifest)
        require(manifest["releaseId"] == release_id, "manifest release ID mismatch")
        self.manifest = manifest
        self.local_image = Path(local_image) if local_image else None
        if self.local_image:
            require(
                self.local_image.stat().st_size == manifest["imageBytes"]
                and file_sha256(self.local_image) == manifest["imageSha256"],
                "local image identity mismatch",
            )
        self.directory = Path(directory)
        self.cache = self.directory / "blocks"
        self.cache.mkdir(parents=True, exist_ok=True)
        self.fetcher = RangeFetcher(repo, assets)
        self.profile = Path(profile) if profile else None
        if self.profile:
            self.profile.parent.mkdir(parents=True, exist_ok=True)
            self.profile.write_text("")
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
        with path.open("rb") as stream:
            data = stream.read(block["size"] + 1)
        if len(data) == block["size"] and sha256(data) == block["sha256"]:
            return data
        path.unlink()
        return None

    def _fetch_group(self, indices, data_by_index):
        shard, first = self.blocks[indices[0]]
        last = self.blocks[indices[-1]][1]
        start = first["offset"] - shard["offset"]
        end = last["offset"] - shard["offset"] + last["size"] - 1
        if self.local_image:
            with self.local_image.open("rb") as source:
                source.seek(shard["offset"] + start)
                payload = source.read(end - start + 1)
        else:
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
        require(
            type(start) is int and type(length) is int,
            "image reads require integer offsets",
        )
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
            if self.profile:
                with self.profile.open("a") as stream:
                    for index in range(first, last + 1):
                        print(index, file=stream)
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


def eager(repo, release_id, manifest_identity, directory):
    manifest, assets = load_manifest(repo, release_id, manifest_identity, directory)
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

    try:
        with ThreadPoolExecutor(max_workers=4) as executor:
            list(executor.map(download, enumerate(manifest["shards"])))
        if len(shard_paths) == 1:
            require(
                manifest["shards"][0]["sha256"] == manifest["imageSha256"],
                "image digest mismatch",
            )
            os.replace(shard_paths[0], temporary)
        else:
            with temporary.open("xb") as image:
                for path in shard_paths:
                    with path.open("rb") as source:
                        shutil.copyfileobj(source, image)
            require(
                file_sha256(temporary) == manifest["imageSha256"],
                "assembled image digest mismatch",
            )
        require(
            temporary.stat().st_size == manifest["imageBytes"],
            "assembled image size mismatch",
        )
        os.replace(temporary, image_path)
    finally:
        temporary.unlink(missing_ok=True)
        for path in shard_paths:
            path.unlink(missing_ok=True)
    return {
        "releaseId": release_id,
        "manifestSha256": manifest_identity["sha256"],
        "image": str(image_path),
        "imageSha256": manifest["imageSha256"],
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

    def __init__(self, store):
        self.store = store
        self.fault = store.directory / "backing-failure"
        super().__init__(("127.0.0.1", 0), ImageHandler)

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address


class ImageHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(60)

    def do_HEAD(self):
        self.respond(False)

    def do_GET(self):
        self.respond(True)

    def respond(self, send_body):
        if (
            self.headers.get("Transfer-Encoding")
            or self.headers.get("Content-Length", "0") != "0"
        ):
            self.close_connection = True
            self.send_error(400)
            return
        size = self.server.store.manifest["imageBytes"]
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
                while sent < length:
                    try:
                        data = self.server.store.read(
                            start + sent, min(1024 * 1024, length - sent)
                        )
                    except Exception:
                        self.close_connection = True
                        self.server.fault.write_text("cache-backing-failure\n")
                        status = 502
                        break
                    self.wfile.write(data)
                    sent += len(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def log_message(self, *_args):
        pass


def serve(repo, release_id, manifest_identity, directory, ready):
    manifest, assets = load_manifest(repo, release_id, manifest_identity, directory)
    store = BlockStore(repo, release_id, manifest, assets, directory)
    if manifest.get("component") == "darwin-image-aarch64-darwin":
        require("hotPack" in manifest, "missing bound hot pack")
        pin = manifest["hotPack"]
        from ci_cache_generation import identity

        require(
            pin["assetId"] in assets
            and identity(assets[pin["assetId"]]) == pin
            and pin["size"] <= SHARD_SIZE,
            "hot pack asset mismatch",
        )
        hot_pack = Path(directory) / "hot-pack.bin"
        store.fetcher.fetch_to(pin["assetId"], 0, pin["size"] - 1, hot_pack)
        require(
            file_sha256(hot_pack) == pin["sha256"]
            and Path(hot_pack).stat().st_size == pin["size"],
            "hot pack identity mismatch",
        )
        import_hot_pack(hot_pack, store)
    run_server(store, ready)


def profile_manifest(manifest):
    if "releaseId" not in manifest:
        validate_manifest(manifest, require_assets=False)
        manifest = {
            **manifest,
            "releaseId": 1,
            "shards": [
                {**shard, "assetId": index + 1}
                for index, shard in enumerate(manifest["shards"])
            ],
        }
    validate_manifest(manifest)
    return manifest


def serve_local(image, manifest_path, directory, ready, profile):
    manifest = profile_manifest(json.loads(Path(manifest_path).read_text()))
    Path(directory).mkdir(parents=True, exist_ok=False)
    assets = {
        s["assetId"]: {
            "id": s["assetId"],
            "name": s["name"],
            "size": s["size"],
            "digest": "sha256:" + s["sha256"],
            "browser_download_url": "",
        }
        for s in manifest["shards"]
    }
    store = BlockStore(
        "",
        manifest["releaseId"],
        manifest,
        assets,
        directory,
        local_image=image,
        profile=profile,
    )
    run_server(store, ready)


def run_server(store, ready):
    server = ImageServer(store)
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
    for name in ("eager", "serve"):
        command = commands.add_parser(name)
        command.add_argument("--repo", required=True)
        command.add_argument("--selection", required=True, type=Path)
        command.add_argument("--component", required=True)
        command.add_argument("--directory", required=True, type=Path)
        if name == "serve":
            command.add_argument("--ready", required=True, type=Path)
    local = commands.add_parser("serve-local")
    for flag in ("image", "manifest", "directory", "ready", "profile"):
        local.add_argument("--" + flag, required=True, type=Path)
    args = parser.parse_args()
    if args.command == "pack":
        result = pack_image(args.image, args.output)
    elif args.command == "pack-hot":
        result = pack_hot(args.image, args.manifest, args.profile, args.output)
    elif args.command == "serve-local":
        result = serve_local(
            args.image, args.manifest, args.directory, args.ready, args.profile
        )
    else:
        from ci_cache_generation import read_selection

        selection = read_selection(args.selection, args.repo)
        identity = selection["generation"]["components"][args.component]
        release_id = selection["generation"]["releaseId"]
        if args.command == "eager":
            result = eager(args.repo, release_id, identity, args.directory)
        else:
            result = serve(
                args.repo,
                release_id,
                identity,
                args.directory,
                args.ready,
            )
    if result is not None:
        print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
