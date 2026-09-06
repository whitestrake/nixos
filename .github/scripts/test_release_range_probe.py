"""Local protocol checks; these create no releases."""

import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import unittest

spec = importlib.util.spec_from_file_location(
    "probe", Path(__file__).with_name("release-range-probe.py")
)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class RangeChecks(unittest.TestCase):
    def test_partial_and_reject_full_or_wrong_bytes(self):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                assert self.headers["Range"] == "bytes=0-3"
                status, data = {
                    "/ok": (206, b"abcd"),
                    "/whole": (200, b"abcd"),
                    "/wrong": (206, b"wxyz"),
                    "/long": (206, b"abcde"),
                    "/missing-range": (206, b"abcd"),
                }[self.path]
                self.send_response(status)
                self.send_header("Content-Length", len(data))
                if self.path != "/missing-range":
                    self.send_header("Content-Range", "bytes 0-3/4")
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            asset = {"id": 123, "size": 4}
            records = []
            for path in ("ok", "whole", "wrong", "long", "missing-range"):
                asset["browser_download_url"] = (
                    f"http://127.0.0.1:{server.server_port}/{path}"
                )
                if path == "ok":
                    self.assertEqual(
                        probe.request_range(asset, "bytes=0-3", b"abcd", records),
                        b"abcd",
                    )
                    self.assertEqual(
                        probe.request_range(asset, "bytes=-4", b"abcd", records),
                        b"abcd",
                    )
                else:
                    with self.assertRaises(AssertionError):
                        probe.request_range(asset, "bytes=0-3", b"abcd", records)
            self.assertEqual(len(records), 6)
        finally:
            server.shutdown()
            server.server_close()
            worker.join()


if __name__ == "__main__":
    unittest.main()
