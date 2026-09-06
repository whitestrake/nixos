import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error


SCRIPT = Path(__file__).with_name("darwin-release-image.py")
SPEC = importlib.util.spec_from_file_location("darwin_release_image", SCRIPT)
IMAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMAGE)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Origin:
    def __init__(self, data):
        self.data = data
        self.ranges = []
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
                if byte_range is None:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(outer.data)))
                    self.end_headers()
                    self.wfile.write(outer.data)
                    return
                start, end = map(int, byte_range[6:].split("-"))
                outer.ranges.append((start, end))
                body = outer.data[start : end + 1]
                self.send_response(206)
                self.send_header(
                    "Content-Range", f"bytes {start}-{end}/{len(outer.data)}"
                )
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

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
        "schema": "darwin-release-image-v1",
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


class ReleaseImageTest(unittest.TestCase):
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
                with self.assertRaises(AssertionError):
                    corrupt.read(4, 1)
        finally:
            origin.close()

    def test_manifest_sha_is_checked_before_json_is_trusted(self):
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
                with self.assertRaises(AssertionError):
                    IMAGE.load_manifest(
                        "owner/repo", 7, "0" * 64, Path(directory) / "reader"
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
                finally:
                    server.shutdown()
                    server.server_close()
                    worker.join()
        finally:
            origin.close()

    def test_eager_reassembles_and_verifies_the_full_image(self):
        origin = Origin(b"abcdefgh")
        original = IMAGE.load_manifest
        try:
            manifest, assets = fixture(b"abcdefgh", origin.url())

            def load(_repo, _release_id, _manifest_sha, directory):
                Path(directory).mkdir(parents=True)
                return manifest, assets

            IMAGE.load_manifest = load
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "reader"
                result = IMAGE.eager("owner/repo", 7, "0" * 64, root)
                self.assertEqual(Path(result["image"]).read_bytes(), b"abcdefgh")
                self.assertEqual(
                    (result["requestCount"], result["responseBytes"]), (1, 8)
                )
        finally:
            IMAGE.load_manifest = original
            origin.close()

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
            with self.assertRaises(AssertionError):
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
            with self.assertRaises(AssertionError):
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
            with self.assertRaises(AssertionError):
                IMAGE.import_hot_pack(hot, store)
            hot.write_bytes(original[:-1])
            with self.assertRaises(AssertionError):
                IMAGE.import_hot_pack(hot, store)


if __name__ == "__main__":
    unittest.main()
