"""Check the Komodo open-alert collector against a fake Core read API.

Usage: check_komodo_alerts.py SCRIPT

Runs SCRIPT (modules/aspects/services/komodo-alerts.sh) under bash with
errexit, nounset and pipefail, as writeShellApplication does, and checks that
it follows ListAlerts' pages, reports when its page cap cuts the list short,
keeps alerts that share a server and severity apart, and fails outright when a
page cannot be read.
"""

import http.server
import json
import os
import subprocess
import sys
import threading

PAGE = 100


def alerts():
    out = [
        {
            "_id": {"$oid": f"u{i:03d}"},
            "ts": 1792052000000 + i,
            "resolved": False,
            "level": "CRITICAL",
            "target": {"type": "Server", "id": f"srv{i}"},
            "data": {
                "type": "ServerUnreachable",
                "data": {
                    "id": f"srv{i}",
                    "name": f"host {i}",
                    "region": None,
                    "err": None,
                },
            },
            "resolved_ts": None,
        }
        for i in range(PAGE + 1)
    ]
    # Komodo opens a disk alert per path, so one server can hold two at the
    # same severity; only the id and path tell them apart.
    for n, path in enumerate(["/", "/mnt/data, x=1"]):
        out.append(
            {
                "_id": {"$oid": f"d{n}"},
                "ts": 1792051000000,
                "resolved": False,
                "level": "WARNING",
                "target": {"type": "Server", "id": "srv2"},
                "data": {
                    "type": "ServerDisk",
                    "data": {
                        "id": "srv2",
                        "name": "rapier",
                        "path": path,
                        "used_gb": 90.0,
                        "total_gb": 100.0,
                    },
                },
                "resolved_ts": None,
            }
        )
    return out


ALERTS = alerts()


class Core(http.server.BaseHTTPRequestHandler):
    fail_page = None

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert request["type"] == "ListAlerts", request
        assert request["params"]["query"] == {"resolved": False}, request
        assert (
            self.headers["x-api-key"] == "key"
            and self.headers["x-api-secret"] == "secret"
        )
        page = request["params"]["page"]
        if page == Core.fail_page:
            self.send_response(500)
            self.end_headers()
            return
        chunk = ALERTS[page * PAGE : (page + 1) * PAGE]
        body = json.dumps(
            {"alerts": chunk, "next_page": page + 1 if len(chunk) == PAGE else None}
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def run(script, url, **env):
    environment = dict(
        os.environ,
        KOMODO_READ_URL=url,
        KOMODO_MONITOR_KEY="key",
        KOMODO_MONITOR_SECRET="secret",
        **env,
    )
    return subprocess.run(
        ["bash", "-euo", "pipefail", script],
        env=environment,
        capture_output=True,
        text=True,
    )


def main():
    script = sys.argv[1]
    server = http.server.HTTPServer(("127.0.0.1", 0), Core)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}/read"

    result = run(script, url)
    assert result.returncode == 0, result.stderr
    lines = result.stdout.splitlines()
    alerts = [line for line in lines if line.startswith("komodo_alert,")]
    assert len(alerts) == len(ALERTS), (
        f"collected {len(alerts)} of {len(ALERTS)} alerts"
    )
    assert len({line.split(" ")[0] for line in alerts}) == len(ALERTS), (
        "alerts share a tag set"
    )
    assert lines[-1] == "komodo_alert_collection pages=2i,overflow=0i", lines[-1]
    assert (
        "komodo_alert,id=u000,level=CRITICAL,target_type=Server,target_id=srv0,alert_type=ServerUnreachable,name=host\\ 0 ts=1792052000000i"
        in alerts
    )
    assert (
        "komodo_alert,id=d1,level=WARNING,target_type=Server,target_id=srv2,alert_type=ServerDisk,name=rapier,path=/mnt/data\\,\\ x\\=1 ts=1792051000000i"
        in alerts
    )

    result = run(script, url, KOMODO_ALERT_MAX_PAGES="1")
    assert result.returncode == 0, result.stderr
    lines = result.stdout.splitlines()
    assert sum(line.startswith("komodo_alert,") for line in lines) == PAGE
    assert lines[-1] == "komodo_alert_collection pages=1i,overflow=1i", lines[-1]

    Core.fail_page = 1
    result = run(script, url)
    assert result.returncode != 0, "a failed page must fail the run"
    assert result.stdout == "", "a failed run must print nothing"
    print("komodo-alerts: ok")


if __name__ == "__main__":
    main()
