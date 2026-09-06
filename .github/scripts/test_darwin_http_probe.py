import http.client
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("darwin-http-probe.py")
SPEC = importlib.util.spec_from_file_location("darwin_http_probe", SCRIPT)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class ServerTest(unittest.TestCase):
    def test_serves_exact_file_and_single_ranges(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / "fixture.dmg"
            log = root / "requests.jsonl"
            image.write_bytes(b"0123456789")
            with patch("socket.getfqdn", side_effect=AssertionError("unexpected DNS")):
                server = PROBE.make_server(image, log)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                connection = http.client.HTTPConnection(*server.server_address)
                cases = [
                    ("HEAD", None, 200, b"", "10"),
                    ("GET", None, 200, b"0123456789", "10"),
                    ("GET", "bytes=2-5", 206, b"2345", "4"),
                    ("GET", "bytes=7-", 206, b"789", "3"),
                    ("GET", "bytes=-3", 206, b"789", "3"),
                    ("GET", "bytes=0-1,4-5", 416, b"", "0"),
                ]
                for method, byte_range, status, body, length in cases:
                    headers = {"Range": byte_range} if byte_range else {}
                    connection.request(method, "/image", headers=headers)
                    response = connection.getresponse()
                    self.assertEqual(response.status, status)
                    self.assertEqual(response.read(), body)
                    self.assertEqual(response.getheader("Content-Length"), length)
                connection.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join()

            events = [json.loads(line) for line in log.read_text().splitlines()]
            starts = [event for event in events if event["event"] == "start"]
            records = [event for event in events if event["event"] == "finish"]
            self.assertEqual(len(starts), 6)
            self.assertEqual(
                [event["requestId"] for event in starts],
                [event["requestId"] for event in records],
            )
            self.assertEqual(
                [record["responseBytes"] for record in records], [0, 10, 4, 3, 3, 0]
            )
            self.assertEqual(
                [
                    (record["responseStart"], record["responseEnd"])
                    for record in records
                ],
                [(0, 9), (0, 9), (2, 5), (7, 9), (7, 9), (None, None)],
            )
            self.assertEqual(records[2]["range"], "bytes=2-5")
            self.assertTrue(
                all(
                    record["startedMonotonicNs"] <= record["finishedMonotonicNs"]
                    for record in records
                )
            )


if __name__ == "__main__":
    unittest.main()
