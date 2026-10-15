"""Check the Komodo open-alert collector against a fake Core read API.

Usage: check_komodo_alerts.py SCRIPT

Runs SCRIPT (modules/aspects/services/komodo-alerts.sh) under bash with
errexit, nounset and pipefail, as writeShellApplication does, and checks that
it exports only the fixed series set: one series per unreachable server, 18
summary counts and two collection samples. It checks that repeated outages on
one server reuse its series, that counts stay right for many alerts and for
unknown types and levels, that a run cut short by the page cap or the server
budget prints only the collection samples, that a failed or malformed read
prints nothing, and that the API key and secret never reach a process's
arguments.
"""

import http.server
import json
import os
import re
import subprocess
import sys
import threading
from pathlib import Path
from typing import ClassVar

PAGE = 100
KEY = "fixture-key-4f1c"
SECRET = "fixture-secret-9b7e"
NOW = 1792052000000
NS = f"{NOW}000000"
TYPES = [
    "ServerCpu",
    "ServerMem",
    "ServerDisk",
    "ServerVersionMismatch",
    "ResourceSyncPendingUpdates",
    "Other",
]
LEVELS = ["WARNING", "CRITICAL", "OTHER"]
LINE = re.compile(
    r"^(komodo_alert,alert_type=ServerUnreachable,target_id=[A-Za-z0-9_-]+ ts=\d+i"
    r"|komodo_alert_open,alert_type=[A-Za-z]+,level=[A-Z]+ count=\d+i"
    r"|komodo_alert_collection pages=\d+i,overflow=[01]i) " + NS + "$"
)


def alert(n, kind, ts, target="srv0", level="WARNING", **data):
    return {
        "_id": {"$oid": f"a{n:05d}"},
        "ts": ts,
        "resolved": False,
        "level": level,
        "target": {"type": "Server", "id": target},
        "data": {"type": kind, "data": {"id": target, "name": "host 0", **data}},
        "resolved_ts": None,
    }


def unreachable(n, target, ts=NOW - 5000):
    return alert(n, "ServerUnreachable", ts, target=target, level="CRITICAL")


class Core(http.server.BaseHTTPRequestHandler):
    alerts: ClassVar[list] = []
    fail_page = None
    # Raw response body for a page, for malformed replies.
    raw: ClassVar[dict] = {}
    # Serve each page one alert early, so the last alert of a page shows up
    # again at the top of the next, as an insert between reads would cause.
    overlap = False
    requests = 0

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert request["type"] == "ListAlerts", request
        assert request["params"]["query"] == {"resolved": False}, request
        assert (
            self.headers["x-api-key"] == KEY and self.headers["x-api-secret"] == SECRET
        )
        # curl is still running while this request is served, so its
        # arguments are visible to anyone listing processes.
        for cmdline in Path("/proc").glob("[0-9]*/cmdline"):
            try:
                args = cmdline.read_bytes()
            except OSError:
                continue
            assert KEY.encode() not in args and SECRET.encode() not in args, (
                f"credentials in {cmdline}: {args!r}"
            )
        Core.requests += 1
        page = request["params"]["page"]
        if page == Core.fail_page:
            self.send_response(500)
            self.end_headers()
            return
        if page in Core.raw:
            body = Core.raw[page].encode()
        else:
            start = page * PAGE - (1 if Core.overlap and page else 0)
            chunk = Core.alerts[start : start + PAGE]
            # As Komodo does: a full page always offers a next one.
            body = json.dumps(
                {"alerts": chunk, "next_page": page + 1 if len(chunk) == PAGE else None}
            ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def serve(alerts, fail_page=None, raw=None, overlap=False):
    Core.alerts = alerts
    Core.fail_page = fail_page
    Core.raw = raw or {}
    Core.overlap = overlap


def run(script, url, **env):
    environment = dict(
        os.environ,
        KOMODO_READ_URL=url,
        KOMODO_MONITOR_KEY=KEY,
        KOMODO_MONITOR_SECRET=SECRET,
        KOMODO_ALERT_NOW_MS=str(NOW),
        **env,
    )
    return subprocess.run(
        ["bash", "-euo", "pipefail", script],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


def collect(script, url, **env):
    """Run a collection that must succeed; return its lines, all well formed."""
    result = run(script, url, **env)
    assert result.returncode == 0, result.stderr
    lines = result.stdout.splitlines()
    for line in lines:
        assert LINE.match(line), f"unexpected line: {line!r}"
    assert len({line.split(" ")[0] for line in lines}) == len(lines), (
        "two lines share a series"
    )
    return lines


def fails(script, url, why):
    result = run(script, url)
    assert result.returncode != 0, f"{why} must fail the run"
    assert result.stdout == "", f"{why} must print nothing"


def counts(lines):
    out = {}
    for line in lines:
        m = re.match(
            r"komodo_alert_open,alert_type=(\w+),level=(\w+) count=(\d+)i", line
        )
        if m:
            out[(m[1], m[2])] = int(m[3])
    return out


def down(lines):
    return {
        line.split(" ")[0]: line.split(" ")[1]
        for line in lines
        if line.startswith("komodo_alert,")
    }


def complete(lines, pages):
    """A complete run: every bucket, controls last, nothing over budget."""
    assert len(counts(lines)) == len(TYPES) * len(LEVELS), "missing summary buckets"
    assert lines[-1] == f"komodo_alert_collection pages={pages}i,overflow=0i {NS}", (
        lines[-1]
    )
    assert len(lines) <= 29 + 18 + 1, f"{len(lines)} samples is over budget"


def control_only(lines, pages):
    assert lines == [f"komodo_alert_collection pages={pages}i,overflow=1i {NS}"], lines


def main():
    script = sys.argv[1]
    server = http.server.HTTPServer(("127.0.0.1", 0), Core)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}/read"

    # Nothing open: explicit zeroes for every bucket.
    serve([])
    lines = collect(script, url)
    complete(lines, 1)
    assert set(counts(lines).values()) == {0} and not down(lines)

    # 999 alerts across ten pages land in the 18 fixed buckets. Unknown types
    # and levels go to Other and OTHER; two disk alerts on one server count
    # twice in one bucket.
    kinds = ["ServerCpu", "ServerMem", "ServerDisk", "ServerVersionMismatch"]
    kinds += ["ResourceSyncPendingUpdates", "SwarmUnhealthy", "Custom", "Odd kind"]
    levels = ["WARNING", "CRITICAL", "OK", "unheard of"]
    many = [
        alert(
            n,
            kinds[n % len(kinds)],
            NOW - 61000,
            level=levels[n % 3 if n % 7 else 3],
            path=f"/mnt/{n}",
        )
        for n in range(999)
    ]
    serve(many)
    lines = collect(script, url)
    complete(lines, 10)
    want = {(t, lv): 0 for t in TYPES for lv in LEVELS}
    for a in many:
        t = a["data"]["type"] if a["data"]["type"] in TYPES else "Other"
        lv = a["level"] if a["level"] in LEVELS else "OTHER"
        want[(t, lv)] += 1
    assert counts(lines) == want, counts(lines)
    assert sum(counts(lines).values()) == 999 and not down(lines)
    assert want[("ServerDisk", "WARNING")] >= 2

    # Exactly 1,000 fills the tenth page, so Komodo offers an eleventh: the
    # page cap stops there and only the collection samples go out.
    serve(many + [alert(999, "ServerCpu", NOW - 61000)])
    control_only(collect(script, url), 10)

    # The page cap on its own, at one page.
    serve(many[:101])
    control_only(collect(script, url, KOMODO_ALERT_MAX_PAGES="1"), 1)

    # Only alerts open for more than a minute at the run's start are counted.
    serve(
        [
            alert(0, "ServerCpu", NOW - 59999),
            alert(1, "ServerCpu", NOW - 60000),
            alert(2, "ServerCpu", NOW - 60001),
            alert(3, "ServerCpu", NOW - 600000),
        ]
    )
    assert counts(collect(script, url))[("ServerCpu", "WARNING")] == 2

    # Unreachable servers: one series each, valued with the earliest open
    # alert, whatever their age (Grafana applies the ten seconds).
    serve(
        [
            unreachable(0, "srv0", NOW - 3000),
            unreachable(1, "srv0", NOW - 9000),
            unreachable(2, "srv1", NOW - 120000),
        ]
    )
    assert down(collect(script, url)) == {
        "komodo_alert,alert_type=ServerUnreachable,target_id=srv0": f"ts={NOW - 9000}i",
        "komodo_alert,alert_type=ServerUnreachable,target_id=srv1": f"ts={NOW - 120000}i",
    }

    # 1,000 outages in turn on one server keep one series; only its value moves.
    seen = set()
    for n in range(1000):
        serve([unreachable(n, "srv0", NOW - 20000 + n)])
        series = down(collect(script, url))
        assert list(series.values()) == [f"ts={NOW - 20000 + n}i"], series
        seen |= set(series)
    assert len(seen) == 1, seen

    # 29 unreachable servers fit the budget; a 30th sends only the controls.
    serve([unreachable(n, f"srv{n}") for n in range(29)])
    lines = collect(script, url)
    complete(lines, 1)
    assert len(down(lines)) == 29
    serve([unreachable(n, f"srv{n}") for n in range(30)])
    control_only(collect(script, url), 1)
    # The budget counts servers, not alerts.
    serve([unreachable(n, f"srv{n % 29}") for n in range(60)])
    assert len(down(collect(script, url))) == 29

    # An alert read twice across pages counts once.
    serve(many[:150], overlap=True)
    lines = collect(script, url)
    complete(lines, 2)
    assert sum(counts(lines).values()) == 150

    # Failed and malformed reads fail the run and print nothing.
    serve(many[:150], fail_page=1)
    fails(script, url, "a failed second page")
    for raw, why in [
        ("not json", "a non-JSON page"),
        ('{"alerts": "x", "next_page": null}', "a page without an alert list"),
        ('{"alerts": [], "next_page": "1"}', "a non-numeric next page"),
    ]:
        serve([], raw={0: raw})
        fails(script, url, why)
    for broken, why in [
        ({"ts": None}, "an alert without a time"),
        ({"level": None}, "an alert without a level"),
        ({"target": {"type": "Server", "id": "a b,c=d"}}, "an unsafe target id"),
        ({"data": {}}, "an alert without a type"),
    ]:
        serve([{**unreachable(0, "srv0"), **broken}])
        fails(script, url, why)

    assert Core.requests >= 1000, "the fake Core was never asked"
    print("komodo-alerts: ok")


if __name__ == "__main__":
    main()
