import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import urllib.error


SCRIPT = Path(__file__).with_name("ci_cache_image.py")
SPEC = importlib.util.spec_from_file_location("ci_cache_image", SCRIPT)
IMAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMAGE)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Origin:
    def __init__(self, data, parts=None, delay=0, faults=None):
        self.data = data
        self.parts = parts or {}
        self.delay = delay
        self.faults = faults or {}
        self.ranges = []
        self.active = 0
        self.max_active = 0
        self.lock = threading.Lock()
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/missing":
                    self.send_error(404)
                    return
                if self.path == "/expired":
                    self.send_error(618)
                    return
                byte_range = self.headers.get("Range")
                data = outer.parts.get(self.path.lstrip("/"), outer.data)
                if byte_range is None:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                start, end = map(int, byte_range[6:].split("-"))
                outer.ranges.append((start, end))
                with outer.lock:
                    outer.active += 1
                    outer.max_active = max(outer.max_active, outer.active)
                try:
                    if outer.delay:
                        time.sleep(outer.delay)
                    body = data[start : end + 1]
                    if outer.faults.get(self.path.lstrip("/")) == "corrupt":
                        body = bytes([body[0] ^ 1]) + body[1:]
                    elif outer.faults.get(self.path.lstrip("/")) == "truncate":
                        body = body[:-1]
                    self.send_response(206)
                    self.send_header(
                        "Content-Range", f"bytes {start}-{end}/{len(data)}"
                    )
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                finally:
                    with outer.lock:
                        outer.active -= 1

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def url(self, path="asset"):
        return f"http://127.0.0.1:{self.server.server_port}/{path}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


def fixture(data, url):
    blocks = [data[:4], data[4:]]
    manifest = {
        "schema": "ci-cache-image-v1",
        "releaseId": 7,
        "imageBytes": len(data),
        "imageSha256": digest(data),
        "blockSize": 4,
        "shardSize": 8,
        "shards": [
            {
                "name": "part.bin",
                "offset": 0,
                "size": len(data),
                "sha256": digest(data),
                "assetId": 9,
                "blocks": [
                    {"offset": 0, "size": 4, "sha256": digest(blocks[0])},
                    {"offset": 4, "size": 4, "sha256": digest(blocks[1])},
                ],
            }
        ],
    }
    assets = {
        9: {
            "id": 9,
            "name": "part.bin",
            "size": len(data),
            "digest": "sha256:" + digest(data),
            "browser_download_url": url,
        }
    }
    return manifest, assets


def shard_fixture(parts, origin):
    data = b"".join(parts)
    shards = []
    assets = {}
    offset = 0
    for index, part in enumerate(parts):
        asset_id = 9 + index
        name = f"part-{index}.bin"
        shards.append(
            {
                "name": name,
                "offset": offset,
                "size": len(part),
                "sha256": digest(part),
                "assetId": asset_id,
                "blocks": [
                    {"offset": offset, "size": len(part), "sha256": digest(part)}
                ],
            }
        )
        assets[asset_id] = {
            "id": asset_id,
            "name": name,
            "size": len(part),
            "digest": "sha256:" + digest(part),
            "browser_download_url": origin.url(name),
        }
        offset += len(part)
    return {
        "schema": "ci-cache-image-v1",
        "releaseId": 7,
        "imageBytes": len(data),
        "imageSha256": digest(data),
        "blockSize": 4,
        "shardSize": 4,
        "shards": shards,
    }, assets


def single_fixture(data, url):
    block_size = 4
    blocks = [
        data[offset : offset + block_size] for offset in range(0, len(data), block_size)
    ]
    manifest = {
        "schema": "ci-cache-image-v1",
        "releaseId": 7,
        "imageBytes": len(data),
        "imageSha256": digest(data),
        "blockSize": block_size,
        "shardSize": ((len(data) + block_size - 1) // block_size) * block_size,
        "shards": [
            {
                "name": "image.bin",
                "offset": 0,
                "size": len(data),
                "sha256": digest(data),
                "assetId": 9,
                "blocks": [
                    {
                        "offset": offset,
                        "size": len(block),
                        "sha256": digest(block),
                    }
                    for offset, block in zip(range(0, len(data), block_size), blocks)
                ],
            }
        ],
    }
    assets = {
        9: {
            "id": 9,
            "name": "image.bin",
            "size": len(data),
            "digest": "sha256:" + digest(data),
            "browser_download_url": url,
        }
    }
    return manifest, assets


class ReleaseImageTest(unittest.TestCase):
    def test_authenticated_asset_download_uses_pinned_id_and_checks_size(self):
        asset = {
            "id": 9,
            "size": 4,
            "browser_download_url": "https://attacker.example/unused",
        }
        with patch.object(IMAGE.subprocess, "run") as run:
            run.return_value.stdout = b"data"
            self.assertEqual(IMAGE.gh_download_whole("owner/repo", asset), b"data")
            run.assert_called_once_with(
                [
                    "gh",
                    "api",
                    "repos/owner/repo/releases/assets/9",
                    "--header",
                    "Accept: application/octet-stream",
                ],
                stdout=IMAGE.subprocess.PIPE,
                stderr=IMAGE.subprocess.PIPE,
                check=True,
                timeout=60,
            )
            run.return_value.stdout = b"short"
            with self.assertRaisesRegex(ValueError, "asset size mismatch"):
                IMAGE.gh_download_whole("owner/repo", asset)

    def test_local_producer_uses_verified_blocks_and_numeric_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "local.img"
            source.write_bytes(b"abcdefgh")
            manifest, assets = fixture(b"abcdefgh", "")
            log = IMAGE.WireLog(root / "profile.jsonl")
            store = IMAGE.BlockStore(
                "", 7, manifest, assets, root / "cache", log, local_image=source
            )
            self.assertEqual(store.read(0, 4), b"abcd")
            record = json.loads((root / "profile.jsonl").read_text())
            self.assertTrue(
                all(type(value) in (int, float) for value in record.values())
            )
            source.write_bytes(b"abcdWXYZ")
            with self.assertRaises(ValueError):
                store.read(4, 4)

    def test_backing_failure_closes_response_and_leaves_fault_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, assets = fixture(b"abcdefgh", "")
            store = IMAGE.BlockStore("owner/repo", 7, manifest, assets, root)
            server = IMAGE.make_server(store, root / "wire.jsonl")
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                with patch.object(
                    store, "read", side_effect=ValueError("corrupt backing")
                ):
                    connection = http.client.HTTPConnection(
                        *server.server_address, timeout=2
                    )
                    connection.request("GET", "/image")
                    response = connection.getresponse()
                    with self.assertRaises(http.client.IncompleteRead):
                        response.read()
                    connection.close()
                self.assertEqual(
                    (root / "backing-failure").read_text(), "cache-backing-failure\n"
                )
            finally:
                server.shutdown()
                server.server_close()
                worker.join()

    def test_native_response_reads_in_bounded_chunks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, assets = fixture(b"abcdefgh", "")
            store = IMAGE.BlockStore("owner/repo", 7, manifest, assets, root)
            store.manifest["imageBytes"] = 3 * 1024 * 1024 + 1
            sizes = []

            def read(_start, length):
                sizes.append(length)
                return b"x" * length

            server = IMAGE.make_server(store, root / "wire.jsonl")
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                with patch.object(store, "read", side_effect=read):
                    connection = http.client.HTTPConnection(
                        *server.server_address, timeout=2
                    )
                    connection.request("GET", "/image")
                    self.assertEqual(
                        len(connection.getresponse().read()),
                        store.manifest["imageBytes"],
                    )
                    connection.close()
                self.assertEqual(sizes, [1024 * 1024] * 3 + [1])
            finally:
                server.shutdown()
                server.server_close()
                worker.join()

    def test_cli_operations_have_bounded_timeouts(self):
        failure = IMAGE.subprocess.TimeoutExpired("gh", 60)
        for operation, args, timeout in (
            (IMAGE.gh_api, ("owner/repo", "releases/1"), 60),
            (IMAGE.gh_upload, ("owner/repo", "tag", "image.bin"), 600),
        ):
            with patch.object(IMAGE.subprocess, "run", side_effect=failure) as run:
                with self.assertRaises(IMAGE.subprocess.TimeoutExpired):
                    operation(*args)
                self.assertEqual(run.call_args.kwargs["timeout"], timeout)

    def test_pack_splits_at_boundary_and_hashes_verification_blocks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.dmg"
            source.write_bytes(b"abcdefghij")
            result = IMAGE.pack_image(
                source, root / "packed", shard_size=8, block_size=4
            )
            manifest = json.loads((root / "packed/draft-manifest.json").read_text())

            self.assertEqual(result["shardCount"], 2)
            self.assertEqual([s["size"] for s in manifest["shards"]], [8, 2])
            self.assertEqual(
                [[b["size"] for b in s["blocks"]] for s in manifest["shards"]],
                [[4, 4], [2]],
            )
            self.assertEqual(manifest["imageSha256"], digest(b"abcdefghij"))

    def test_verified_store_rejects_missing_and_corrupt_blocks_and_reads_boundary(self):
        origin = Origin(b"abcdefgh")
        try:
            with tempfile.TemporaryDirectory() as directory:
                manifest, assets = fixture(b"abcdefgh", origin.url())
                store = IMAGE.BlockStore(
                    "owner/repo", 7, manifest, assets, Path(directory)
                )
                self.assertEqual(store.read(3, 3), b"def")
                self.assertEqual(origin.ranges, [(0, 7)])
                self.assertEqual(store.read(3, 3), b"def")
                self.assertEqual(origin.ranges, [(0, 7)])

                manifest, assets = fixture(b"abcdefgh", origin.url("missing"))
                missing = IMAGE.BlockStore(
                    "owner/repo", 7, manifest, assets, Path(directory) / "missing"
                )
                with self.assertRaises(urllib.error.HTTPError):
                    missing.read(0, 1)

                origin.data = b"abcdWXYZ"
                manifest, assets = fixture(b"abcdefgh", origin.url())
                corrupt = IMAGE.BlockStore(
                    "owner/repo", 7, manifest, assets, Path(directory) / "corrupt"
                )
                with self.assertRaises(ValueError):
                    corrupt.read(4, 1)
        finally:
            origin.close()

    def test_manifest_identity_is_checked_before_json_is_trusted(self):
        origin = Origin(b"not json")
        original = IMAGE.gh_api
        try:
            IMAGE.gh_api = lambda _repo, _endpoint: {
                "id": 7,
                "assets": [
                    {
                        "id": 8,
                        "name": "manifest.json",
                        "size": 8,
                        "digest": "sha256:" + digest(b"not json"),
                        "browser_download_url": origin.url(),
                    }
                ],
            }
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    IMAGE.load_manifest(
                        "owner/repo",
                        7,
                        {
                            "assetId": 8,
                            "name": "manifest.json",
                            "size": 8,
                            "sha256": "0" * 64,
                        },
                        Path(directory) / "reader",
                    )
        finally:
            IMAGE.gh_api = original
            origin.close()

    def test_loopback_server_serves_head_and_cross_block_range(self):
        origin = Origin(b"abcdefgh")
        try:
            with tempfile.TemporaryDirectory() as directory:
                manifest, assets = fixture(b"abcdefgh", origin.url())
                store = IMAGE.BlockStore(
                    "owner/repo", 7, manifest, assets, Path(directory)
                )
                server = IMAGE.make_server(store, Path(directory) / "wire.jsonl")
                worker = threading.Thread(target=server.serve_forever, daemon=True)
                worker.start()
                try:
                    connection = http.client.HTTPConnection(*server.server_address)
                    connection.request("HEAD", "/image")
                    response = connection.getresponse()
                    self.assertEqual((response.status, response.read()), (200, b""))
                    connection.request("GET", "/image", headers={"Range": "bytes=3-5"})
                    response = connection.getresponse()
                    self.assertEqual((response.status, response.read()), (206, b"def"))
                    self.assertEqual(response.getheader("Content-Range"), "bytes 3-5/8")
                    connection.close()
                    for _ in range(100):
                        interface = [
                            json.loads(line)
                            for line in (Path(directory) / "wire.jsonl")
                            .read_text()
                            .splitlines()
                            if json.loads(line)["kind"] == 2
                        ]
                        if len(interface) == 2:
                            break
                        time.sleep(0.01)
                    self.assertEqual(len(interface), 2)
                    self.assertEqual(
                        len({record["clientPort"] for record in interface}), 1
                    )
                    for record in interface:
                        self.assertGreater(record["clientPort"], 0)
                        self.assertLessEqual(record["startedNs"], record["finishedNs"])
                        self.assertEqual(
                            record["elapsedNs"],
                            record["finishedNs"] - record["startedNs"],
                        )
                finally:
                    server.shutdown()
                    server.server_close()
                    worker.join()
        finally:
            origin.close()

    def test_eager_reassembles_and_verifies_the_full_image(self):
        parts = [b"abcd", b"efgh"]
        origin = Origin(
            b"",
            parts={f"part-{i}.bin": part for i, part in enumerate(parts)},
            delay=0.05,
        )
        original = IMAGE.load_manifest
        try:
            manifest, assets = shard_fixture(parts, origin)

            def load(_repo, _release_id, _manifest_identity, directory):
                Path(directory).mkdir(parents=True)
                return manifest, assets

            IMAGE.load_manifest = load
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "reader"
                result = IMAGE.eager(
                    "owner/repo", 7, {"sha256": "0" * 64}, root, workers=2
                )
                self.assertEqual(Path(result["image"]).read_bytes(), b"abcdefgh")
                self.assertEqual(
                    (result["requestCount"], result["responseBytes"]), (2, 8)
                )
                self.assertEqual(result["workers"], 2)
                self.assertGreaterEqual(result["selectionSeconds"], 0)
                self.assertGreaterEqual(result["restoreSeconds"], 0.05)
                self.assertGreaterEqual(origin.max_active, 2)
                self.assertEqual(list(root.glob("image.dmg.*")), [])
        finally:
            IMAGE.load_manifest = original
            origin.close()

    def test_eager_rejects_corrupt_or_truncated_shards_without_promoting_image(self):
        original = IMAGE.load_manifest
        try:
            for fault in ("corrupt", "truncate"):
                with self.subTest(fault=fault):
                    parts = [b"abcd", b"efgh"]
                    origin = Origin(
                        b"",
                        parts={f"part-{i}.bin": part for i, part in enumerate(parts)},
                        faults={"part-1.bin": fault},
                    )
                    manifest, assets = shard_fixture(parts, origin)

                    def load(_repo, _release_id, _manifest_identity, directory):
                        Path(directory).mkdir(parents=True)
                        return manifest, assets

                    IMAGE.load_manifest = load
                    try:
                        with tempfile.TemporaryDirectory() as directory:
                            root = Path(directory) / "reader"
                            with self.assertRaises(ValueError):
                                IMAGE.eager(
                                    "owner/repo",
                                    7,
                                    {"sha256": "0" * 64},
                                    root,
                                    workers=2,
                                )
                            self.assertFalse((root / "image.dmg").exists())
                    finally:
                        origin.close()
        finally:
            IMAGE.load_manifest = original

    def test_eager_single_promotes_one_verified_asset_without_copying(self):
        origin = Origin(b"abcdefgh")
        manifest, assets = single_fixture(b"abcdefgh", origin.url())
        original_fetch_to = IMAGE.RangeFetcher.fetch_to
        downloaded_inode = None

        def fetch_to(fetcher, asset_id, start, end, target):
            nonlocal downloaded_inode
            result = original_fetch_to(fetcher, asset_id, start, end, target)
            downloaded_inode = Path(target).stat().st_ino
            return result

        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "reader"
                with (
                    patch.object(
                        IMAGE,
                        "load_manifest",
                        side_effect=lambda *_args: (root.mkdir(), (manifest, assets))[
                            1
                        ],
                    ),
                    patch.object(
                        IMAGE, "file_sha256", wraps=IMAGE.file_sha256
                    ) as file_digest,
                    patch.object(IMAGE.RangeFetcher, "fetch_to", fetch_to),
                ):
                    result = IMAGE.eager("owner/repo", 7, {"sha256": "0" * 64}, root)

                self.assertEqual(Path(result["image"]).read_bytes(), b"abcdefgh")
                self.assertEqual(Path(result["image"]).stat().st_ino, downloaded_inode)
                self.assertEqual(file_digest.call_count, 1)
                self.assertEqual(origin.ranges, [(0, 7)])
                self.assertEqual(list(root.glob("image.dmg.*")), [])
        finally:
            origin.close()

    def test_eager_single_rejects_bad_payloads_without_promoting_image(self):
        cases = ("corrupt", "truncate", "image-digest")
        for fault in cases:
            with self.subTest(fault=fault):
                origin = Origin(b"abcdefgh", faults={"image.bin": fault})
                manifest, assets = single_fixture(b"abcdefgh", origin.url("image.bin"))
                if fault == "image-digest":
                    manifest["imageSha256"] = digest(b"abcdwxyz")
                    origin.faults.clear()
                try:
                    with tempfile.TemporaryDirectory() as directory:
                        root = Path(directory) / "reader"
                        with patch.object(
                            IMAGE,
                            "load_manifest",
                            side_effect=lambda *_args: (
                                root.mkdir(),
                                (manifest, assets),
                            )[1],
                        ):
                            with self.assertRaises(ValueError):
                                IMAGE.eager("owner/repo", 7, {"sha256": "0" * 64}, root)
                        self.assertFalse((root / "image.dmg").exists())
                        self.assertEqual(list(root.glob("image.dmg.*")), [])
                finally:
                    origin.close()

    def test_manifest_and_range_integrity_checks_survive_python_optimisation(self):
        manifest, _assets = fixture(b"abcdefgh", "http://127.0.0.1/unused")
        manifest["imageBytes"] += 1
        with self.assertRaises(ValueError):
            IMAGE.validate_manifest(manifest)

        assets = {
            9: {
                "id": 9,
                "name": "part.bin",
                "size": 8,
                "digest": "sha256:" + digest(b"abcdefgh"),
                "browser_download_url": "http://127.0.0.1/unused",
            }
        }
        with self.assertRaises(ValueError):
            IMAGE.RangeFetcher("owner/repo", assets).fetch(9, 0, 8)

    def test_expired_redirect_refreshes_only_the_pinned_asset(self):
        origin = Origin(b"abcdefgh")
        try:
            _manifest, assets = fixture(b"abcdefgh", origin.url("expired"))

            def refresh(repo, endpoint):
                self.assertEqual((repo, endpoint), ("owner/repo", "releases/assets/9"))
                return {**assets[9], "browser_download_url": origin.url()}

            fetcher = IMAGE.RangeFetcher("owner/repo", assets, api_call=refresh)
            self.assertEqual(fetcher.fetch(9, 0, 3), b"abcd")
            self.assertEqual(
                [record["status"] for record in fetcher.records], [618, 206]
            )
            self.assertEqual(fetcher.summary()["requestCount"], 2)
        finally:
            origin.close()

    def test_hot_pack_seeds_profiled_blocks_and_unprofiled_blocks_still_fetch(self):
        origin = Origin(b"abcdefgh")
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                image = root / "image.dmg"
                image.write_bytes(b"abcdefgh")
                manifest, assets = fixture(b"abcdefgh", origin.url())
                manifest_path = root / "manifest.json"
                manifest_path.write_text(json.dumps(manifest))
                profile = root / "requests.jsonl"
                profile.write_text(
                    json.dumps(
                        {
                            "kind": 1,
                            "assetId": 9,
                            "start": 0,
                            "end": 3,
                            "status": 206,
                            "valid": 1,
                        }
                    )
                    + "\n"
                )
                hot = root / "hot.bin"
                result = IMAGE.pack_hot(image, manifest_path, profile, hot)
                self.assertEqual((result["blockCount"], result["payloadBytes"]), (1, 4))

                store = IMAGE.BlockStore(
                    "owner/repo", 7, manifest, assets, root / "cache"
                )
                self.assertEqual(IMAGE.import_hot_pack(hot, store), (1, 4))
                self.assertEqual(store.read(0, 1), b"a")
                self.assertEqual(origin.ranges, [])
                self.assertEqual(store.read(4, 1), b"e")
                self.assertEqual(origin.ranges, [(4, 7)])
        finally:
            origin.close()

    def test_hot_pack_rejects_wrong_image_range_corruption_and_missing_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / "image.dmg"
            image.write_bytes(b"abcdefgh")
            manifest, assets = fixture(b"abcdefgh", "http://127.0.0.1/unused")
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps(manifest))
            profile = root / "requests.jsonl"

            image.write_bytes(b"abcdefgX")
            profile.write_text("")
            with self.assertRaises(ValueError):
                IMAGE.pack_hot(image, manifest_path, profile, root / "wrong.bin")

            image.write_bytes(b"abcdefgh")
            profile.write_text(
                json.dumps(
                    {
                        "kind": 1,
                        "assetId": 9,
                        "start": 0,
                        "end": 8,
                        "status": 206,
                        "valid": 1,
                    }
                )
                + "\n"
            )
            with self.assertRaises(ValueError):
                IMAGE.pack_hot(image, manifest_path, profile, root / "range.bin")

            profile.write_text(
                json.dumps(
                    {
                        "kind": 1,
                        "assetId": 9,
                        "start": 0,
                        "end": 3,
                        "status": 206,
                        "valid": 1,
                    }
                )
                + "\n"
            )
            hot = root / "hot.bin"
            IMAGE.pack_hot(image, manifest_path, profile, hot)
            original = hot.read_bytes()
            store = IMAGE.BlockStore("owner/repo", 7, manifest, assets, root / "cache")
            hot.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
            with self.assertRaises(ValueError):
                IMAGE.import_hot_pack(hot, store)
            hot.write_bytes(original[:-1])
            with self.assertRaises(ValueError):
                IMAGE.import_hot_pack(hot, store)


if __name__ == "__main__":
    unittest.main()
