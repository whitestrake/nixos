#!/usr/bin/env python3
"""Serve one disk image over loopback HTTP and log transferred bytes."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time


def parse_range(value, size):
    if not value:
        return None
    if not value.startswith("bytes=") or "," in value:
        raise ValueError("only one byte range is supported")
    first, last = value[6:].split("-", 1)
    if first:
        start = int(first)
        end = min(int(last), size - 1) if last else size - 1
    else:
        length = int(last)
        if length <= 0:
            raise ValueError("empty suffix range")
        start, end = max(0, size - length), size - 1
    if start < 0 or start >= size or end < start:
        raise ValueError("unsatisfiable byte range")
    return start, end


class ProbeServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, image, log):
        self.image = Path(image)
        self.log = Path(log)
        self.log_lock = threading.Lock()
        self.request_count = 0
        super().__init__(address, ProbeHandler)

    def request_id(self):
        with self.log_lock:
            self.request_count += 1
            return self.request_count

    def record(self, entry):
        with self.log_lock, self.log.open("a") as stream:
            print(json.dumps(entry, separators=(",", ":")), file=stream)


class ProbeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_HEAD(self):
        self.respond(False)

    def do_GET(self):
        self.respond(True)

    def respond(self, send_body):
        started = time.monotonic_ns()
        size = self.server.image.stat().st_size
        byte_range = self.headers.get("Range")
        status, start, end = 200, 0, size - 1
        if self.path != "/image":
            status, start, end = 404, 0, -1
        else:
            try:
                parsed = parse_range(byte_range, size)
                if parsed:
                    status, (start, end) = 206, parsed
            except (ValueError, TypeError):
                status, start, end = 416, 0, -1

        request_id = self.server.request_id()
        event = {
            "requestId": request_id,
            "method": self.command,
            "path": self.path,
            "range": byte_range,
            "status": status,
            "responseStart": start if status in (200, 206) else None,
            "responseEnd": end if status in (200, 206) else None,
            "fileBytes": size,
            "startedMonotonicNs": started,
        }
        self.server.record(
            {**event, "event": "start", "responseBytes": 0, "finishedMonotonicNs": None}
        )
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
                with self.server.image.open("rb") as stream:
                    stream.seek(start)
                    remaining = length
                    while remaining:
                        data = stream.read(min(1024 * 1024, remaining))
                        if not data:
                            break
                        self.wfile.write(data)
                        sent += len(data)
                        remaining -= len(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
        self.server.record(
            {
                **event,
                "event": "finish",
                "responseBytes": sent,
                "finishedMonotonicNs": time.monotonic_ns(),
            }
        )

    def log_message(self, *_args):
        pass


def make_server(image, log):
    return ProbeServer(("127.0.0.1", 0), image, log)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--ready", required=True, type=Path)
    args = parser.parse_args()
    server = make_server(args.file, args.log)
    args.ready.write_text(f"http://127.0.0.1:{server.server_port}/image\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
