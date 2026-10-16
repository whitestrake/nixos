"""Check the Komodo alert collector against a fake Core API.

Usage: check_komodo_alerts.py SCRIPT

Runs SCRIPT (modules/aspects/services/komodo-alerts.sh) under bash with
errexit, nounset and pipefail, as writeShellApplication does, and checks that
it exports only the fixed series set: one named series per inventory server,
zero only when it has no unreachable alert and Komodo reports it Ok, 18
summary counts and two collection samples. It checks that an alert resolving
between page reads cannot hide an older one, that an unreachable server with
no open alert (as while Komodo deletes it) fails the run, and that disabled
servers and servers with unreachable alerts off are left out. It checks names with awkward characters, duplicate names and
renames, that repeated outages on one server reuse its series, that counts
stay right for many alerts and for unknown types and levels, that an alert on
a server missing from the inventory is ignored, that a run cut short by the
page cap or the server budget prints only the collection samples, that a
failed or malformed read, an inconsistent inventory or a monitoring user that
cannot read every server prints nothing, and that the API key and secret
never reach a process's arguments.
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
NAME = r"(?:[^\s,=\\]|\\[ ,=]|\\(?![ ,=]))+"
LINE = re.compile(
    r"^(komodo_alert,alert_type=ServerUnreachable,target_id=[0-9a-f]{24},"
    r"target_name=" + NAME + r" ts=\d+i"
    r"|komodo_alert_open,alert_type=[A-Za-z]+,level=[A-Z]+ count=\d+i"
    r"|komodo_alert_collection servers=(-1|\d+)i,overflow=[01]i) " + NS + "$"
)
ADMIN = {"username": "telegraf-monitor", "admin": False, "all": {"Server": "Read"}}


def sid(n):
    """A Komodo server id: a 24-digit hex MongoDB object id."""
    return f"{n:024x}"


def server(n, name=None, state="Ok", alerts=True):
    return {
        "id": sid(n),
        "name": f"host-{n}" if name is None else name,
        "info": {
            "state": state,
            "send_unreachable_alerts": alerts,
            "region": "",
            "version": "v2.3.3",
        },
        "template": False,
        "tags": [],
    }


def inventory(count):
    return [server(n) for n in range(count)]


def alert(n, kind, ts, target=None, level="WARNING", **data):
    target = sid(0) if target is None else target
    return {
        "_id": {"$oid": f"a{n:05d}"},
        "ts": ts,
        "resolved": False,
        "level": level,
        "target": {"type": "Server", "id": target},
        "data": {"type": kind, "data": {"id": target, "name": "old name", **data}},
        "resolved_ts": None,
    }


def unreachable(n, target, ts=NOW - 5000):
    return alert(n, "ServerUnreachable", ts, target=target, level="CRITICAL")


class Core(http.server.BaseHTTPRequestHandler):
    alerts: ClassVar[list] = []
    servers: ClassVar[list] = []
    user: ClassVar[dict] = ADMIN
    # A ListAlerts read (counted from 0), or "servers" or "user", to answer
    # with a 500.
    fail = None
    # Raw response bodies by ListAlerts read, "servers" or "user".
    raw: ClassVar[dict] = {}
    # Called with each ListAlerts read's number once it is answered, to change
    # the open alerts between reads.
    between = None
    reads = 0
    requests = 0
    order: ClassVar[list] = []

    def check(self):
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

    def reply(self, key, value):
        Core.order.append(key)
        if key == Core.fail:
            self.send_response(500)
            self.end_headers()
            return
        body = Core.raw[key].encode() if key in Core.raw else json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        assert self.path == "/user", self.path
        self.check()
        self.reply("user", Core.user)

    def do_POST(self):
        assert self.path == "/read", self.path
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.check()
        if request["type"] == "ListServers":
            # Komodo pages ListServers at 30 unless asked for every server.
            assert request["params"] == {"query": {}, "limit": 0}, request
            self.reply("servers", Core.servers)
            return
        assert request["type"] == "ListAlerts", request
        params = request["params"]
        assert params["page"] == 0, request
        query = dict(params["query"])
        bound = query.pop("ts", {"$lte": None})
        assert query == {"resolved": False} and list(bound) == ["$lte"], request

        # As Komodo does: newest first, 100 a page. The sort is stable, so
        # alerts sharing a time come back in the same order every read.
        def ts(a):
            return a["ts"] if isinstance(a["ts"], (int, float)) else 0

        chunk = sorted(
            (a for a in Core.alerts if bound["$lte"] is None or ts(a) <= bound["$lte"]),
            key=lambda a: -ts(a),
        )[:PAGE]
        read = Core.reads
        Core.reads += 1
        # A full page always offers a next one.
        self.reply(
            read, {"alerts": chunk, "next_page": 1 if len(chunk) == PAGE else None}
        )
        if Core.between:
            Core.between(read)

    def log_message(self, *args):
        pass


def serve(alerts, servers=None, user=None, fail=None, raw=None, between=None):
    Core.alerts = list(alerts)
    Core.servers = inventory(1) if servers is None else servers
    Core.user = ADMIN if user is None else user
    Core.fail = fail
    Core.raw = raw or {}
    Core.between = between
    Core.reads = 0
    Core.order = []


def run(script, url, **env):
    environment = dict(
        os.environ,
        KOMODO_URL=url,
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


def fails(script, url, why, **env):
    result = run(script, url, **env)
    assert result.returncode != 0, f"{why} must fail the run"
    assert result.stdout == "", f"{why} must print nothing"
    assert KEY not in result.stderr and SECRET not in result.stderr, result.stderr


def counts(lines):
    out = {}
    for line in lines:
        m = re.match(
            r"komodo_alert_open,alert_type=(\w+),level=(\w+) count=(\d+)i", line
        )
        if m:
            out[(m[1], m[2])] = int(m[3])
    return out


def servers_of(lines):
    """Server series by id: (escaped name, value)."""
    out = {}
    for line in lines:
        m = re.match(
            r"komodo_alert,alert_type=ServerUnreachable,target_id=(\w+),"
            r"target_name=(" + NAME + r") ts=(\d+)i ",
            line,
        )
        if m:
            out[m[1]] = (m[2], int(m[3]))
    return out


def down(lines):
    return {k: v for k, (_, v) in servers_of(lines).items() if v}


def complete(lines, servers):
    """A complete run: every server and bucket, controls last."""
    assert len(servers_of(lines)) == servers, servers_of(lines)
    assert len(counts(lines)) == len(TYPES) * len(LEVELS), "missing summary buckets"
    assert (
        lines[-1] == f"komodo_alert_collection servers={servers}i,overflow=0i {NS}"
    ), lines[-1]
    assert len(lines) == servers + 18 + 1, f"{len(lines)} samples"
    assert len(lines) + 1 <= 50, f"{len(lines)} samples is over budget"


def control_only(lines):
    assert lines == [f"komodo_alert_collection servers=-1i,overflow=1i {NS}"], lines


def main():
    script = sys.argv[1]
    httpd = http.server.HTTPServer(("127.0.0.1", 0), Core)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{httpd.server_port}"

    # Nothing open: an explicit zero for the one server and every bucket.
    serve([])
    lines = collect(script, url)
    complete(lines, 1)
    assert set(counts(lines).values()) == {0}
    assert servers_of(lines) == {sid(0): ("host-0", 0)}
    # Alerts are read before the inventory, so a server deleted in between
    # drops out instead of reading as healthy.
    assert Core.order == ["user", 0, "servers"], Core.order

    # An empty inventory is a complete observation with no server samples.
    serve([], servers=[])
    complete(collect(script, url), 0)

    # A named unreachable server among healthy ones; the name comes from the
    # inventory, not from the alert.
    serve([unreachable(0, sid(1), NOW - 7000)], servers=inventory(3))
    lines = collect(script, url)
    complete(lines, 3)
    assert servers_of(lines) == {
        sid(0): ("host-0", 0),
        sid(1): ("host-1", NOW - 7000),
        sid(2): ("host-2", 0),
    }

    # Awkward names are escaped as Influx tag values: Telegraf reads a
    # backslash before a space, comma or equals sign as an escape and any
    # other backslash as itself. Two servers may share a name and stay
    # distinct by id. A server listed twice under one name is one server.
    names = {
        0: "web server",
        1: "a,b=c",
        2: "back\\slash",
        3: "café ☕",
        4: "web server",
        5: "x\\,y\\ z",
        6: 'quote"d',
    }
    serve(
        [unreachable(0, sid(4))],
        servers=[server(n, name) for n, name in names.items()] + [server(0, names[0])],
    )
    lines = collect(script, url)
    complete(lines, 7)
    assert servers_of(lines) == {
        sid(0): ("web\\ server", 0),
        sid(1): ("a\\,b\\=c", 0),
        sid(2): ("back\\slash", 0),
        sid(3): ("café\\ ☕", 0),
        sid(4): ("web\\ server", NOW - 5000),
        sid(5): ("x\\\\,y\\\\ z", 0),
        sid(6): ('quote"d', 0),
    }

    # A rename shows the current name under the same id.
    serve([unreachable(0, sid(0))], servers=[server(0, "renamed")])
    assert servers_of(collect(script, url)) == {sid(0): ("renamed", NOW - 5000)}

    # 990 alerts across ten reads land in the 18 fixed buckets (each read
    # after the first repeats the oldest alert of the one before). Unknown types
    # and levels go to Other and OTHER; two disk alerts on one server count
    # twice in one bucket.
    kinds = ["ServerCpu", "ServerMem", "ServerDisk", "ServerVersionMismatch"]
    kinds += ["ResourceSyncPendingUpdates", "SwarmUnhealthy", "Custom", "Odd kind"]
    levels = ["WARNING", "CRITICAL", "OK", "unheard of"]
    many = [
        alert(
            n,
            kinds[n % len(kinds)],
            NOW - 61000 - n,
            level=levels[n % 3 if n % 7 else 3],
            path=f"/mnt/{n}",
        )
        for n in range(990)
    ]
    serve(many)
    lines = collect(script, url)
    complete(lines, 1)
    want = {(t, lv): 0 for t in TYPES for lv in LEVELS}
    for a in many:
        t = a["data"]["type"] if a["data"]["type"] in TYPES else "Other"
        lv = a["level"] if a["level"] in LEVELS else "OTHER"
        want[(t, lv)] += 1
    assert counts(lines) == want, counts(lines)
    assert sum(counts(lines).values()) == 990 and not down(lines)
    assert want[("ServerDisk", "WARNING")] >= 2

    # One more fills the tenth read, so Komodo offers another: the read cap
    # stops there and only the collection samples go out.
    serve([*many, alert(990, "ServerCpu", NOW - 70000)])
    control_only(collect(script, url))

    # The page cap on its own, at one page.
    serve(many[:101])
    control_only(collect(script, url, KOMODO_ALERT_MAX_PAGES="1"))

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

    # Unreachable servers are valued with the earliest open alert, whatever
    # its age (Grafana applies the pending period).
    serve(
        [
            unreachable(0, sid(0), NOW - 3000),
            unreachable(1, sid(0), NOW - 9000),
            unreachable(2, sid(1), NOW - 120000),
        ],
        servers=inventory(2),
    )
    assert down(collect(script, url)) == {sid(0): NOW - 9000, sid(1): NOW - 120000}

    # An alert on a server the inventory no longer lists is ignored: it adds
    # no series, healthy or not, so a removed server can retire.
    serve([unreachable(0, sid(7)), unreachable(1, sid(1))], servers=inventory(2))
    lines = collect(script, url)
    complete(lines, 2)
    assert servers_of(lines) == {sid(0): ("host-0", 0), sid(1): ("host-1", NOW - 5000)}

    # Outages in turn on one server keep one series; only its value moves.
    seen = set()
    for n in range(3):
        serve([unreachable(n, sid(0), NOW - 20000 + n)])
        lines = collect(script, url)
        assert down(lines) == {sid(0): NOW - 20000 + n}
        seen |= {line.split(" ")[0] for line in lines}
    assert len(seen) == 1 + 18 + 1, len(seen)

    # 29 servers fit the budget, healthy or not; a 30th sends only the
    # controls, whatever the alerts.
    serve([unreachable(n, sid(n)) for n in range(29)], servers=inventory(29))
    lines = collect(script, url)
    complete(lines, 29)
    assert len(down(lines)) == 29
    serve([], servers=inventory(29))
    complete(collect(script, url), 29)
    serve([], servers=inventory(30))
    control_only(collect(script, url))
    # The budget counts servers, not alerts.
    serve([unreachable(n, sid(n % 29)) for n in range(60)], servers=inventory(29))
    assert len(down(collect(script, url))) == 29

    # Pages are read by time, so an alert resolving between reads cannot push
    # an older one past a page boundary. With offsets, resolving the newest
    # of 100 newer alerts after the first page would shift the server's
    # unreachable alert from the top of page two to the bottom of page one,
    # already read, and the server would read as healthy.
    newer = [alert(n, "ServerCpu", NOW - 61000 - n) for n in range(100)]
    oldest = unreachable(100, sid(0), NOW - 900000)

    def resolve_newest(read):
        if read == 0:
            Core.alerts.remove(newer[0])

    serve(
        [*newer, oldest],
        servers=[server(0, state="NotOk")],
        between=resolve_newest,
    )
    lines = collect(script, url)
    complete(lines, 1)
    assert down(lines) == {sid(0): NOW - 900000}, servers_of(lines)
    # The resolved alert was read while open; none of the others is lost.
    assert counts(lines)[("ServerCpu", "WARNING")] == 100
    assert Core.order == ["user", 0, 1, "servers"], Core.order

    # An alert opened between reads is newer than every later read asks for,
    # so it is neither counted twice nor in the way.
    def open_newer(read):
        if read == 0:
            Core.alerts.append(alert(999, "ServerCpu", NOW - 1000))

    serve([*newer, oldest], between=open_newer)
    lines = collect(script, url)
    assert counts(lines)[("ServerCpu", "WARNING")] == 100
    assert down(lines) == {sid(0): NOW - 900000}

    # Alerts sharing a time across a page boundary are each read once.
    tied = [alert(n, "ServerMem", NOW - 70000) for n in range(80)]
    serve(
        [alert(100 + n, "ServerCpu", NOW - 61000 - n) for n in range(60)]
        + tied
        + [alert(200 + n, "ServerDisk", NOW - 80000 - n) for n in range(10)]
    )
    lines = collect(script, url)
    complete(lines, 1)
    assert counts(lines)[("ServerMem", "WARNING")] == 80
    assert sum(counts(lines).values()) == 150
    # More than a page sharing one time can never be read past: overflow.
    serve([alert(n, "ServerMem", NOW - 70000) for n in range(101)])
    control_only(collect(script, url))

    # A server is reported reachable only when Komodo says it is Ok. Komodo
    # resolves a server's alerts before deleting it, and opens one only on its
    # second failed check, so an unreachable server with no open alert fails
    # the run rather than reading as recovered.
    serve([], servers=[server(0), server(1, state="NotOk")])
    fails(script, url, "an unreachable server with no open alert")
    # With its alert open it is reported as unreachable, whatever its state.
    for state in ["NotOk", "Ok"]:
        serve([unreachable(0, sid(1))], servers=[server(0), server(1, state=state)])
        assert down(collect(script, url)) == {sid(1): NOW - 5000}
    # Komodo never alerts on a disabled server or one with unreachable alerts
    # off, and closes what it had, so they are left out, alert or not: their
    # series retire as no longer reported.
    serve(
        [unreachable(0, sid(1)), unreachable(1, sid(3))],
        servers=[
            server(0),
            server(1, state="Disabled"),
            server(2, state="NotOk", alerts=False),
            server(3, state="NotOk", alerts=False),
            server(4, alerts=False),
            server(5, state="NotOk"),
        ],
    )
    fails(script, url, "an unreachable server with no open alert among others")
    Core.servers.pop()
    lines = collect(script, url)
    complete(lines, 1)
    assert servers_of(lines) == {sid(0): ("host-0", 0)}

    # The monitoring user must read every server: an admin, or Read or more on
    # all servers. Per-server permissions are not enough, since a server the
    # user cannot see would look removed.
    for user in [
        {"admin": True, "all": {}},
        {"admin": False, "all": {"Server": "Execute"}},
        {"admin": False, "all": {"Server": {"level": "Write", "specific": []}}},
    ]:
        serve([], user=user)
        complete(collect(script, url), 1)
    for user, why in [
        ({"admin": False, "all": {}}, "a user without Read on all servers"),
        ({"admin": False, "all": {"Server": "None"}}, "a user with None on servers"),
        (
            {"admin": False, "all": {"Server": {"level": "None", "specific": []}}},
            "a user with None on servers and specifics",
        ),
        ({"admin": False, "all": {"Stack": "Read"}}, "a user with Read on stacks"),
        ({"admin": "true"}, "an admin flag that is not a boolean"),
    ]:
        serve([], user=user)
        fails(script, url, why)
    serve([], fail="user")
    fails(script, url, "a failed user read")
    serve([], raw={"user": "not json"})
    fails(script, url, "a non-JSON user read")

    # Failed and malformed reads fail the run and print nothing, not even the
    # controls.
    serve(many[:150], fail=1)
    fails(script, url, "a failed second read")
    for raw, why in [
        ("not json", "a non-JSON page"),
        ('{"alerts": "x", "next_page": null}', "a page without an alert list"),
        ('{"alerts": [], "next_page": "1"}', "a non-numeric next page"),
    ]:
        serve([], raw={0: raw})
        fails(script, url, why)
    for broken, why in [
        ({"ts": None}, "an alert without a time"),
        ({"ts": "1"}, "an alert with a time that is not a number"),
        ({"level": None}, "an alert without a level"),
        ({"target": {"type": "Server", "id": 7}}, "a non-string target id"),
        ({"data": {}}, "an alert without a type"),
    ]:
        serve([{**unreachable(0, sid(0)), **broken}])
        fails(script, url, why)
    serve([unreachable(0, sid(0))], fail="servers")
    fails(script, url, "a failed inventory read")
    for raw, why in [
        ("not json", "a non-JSON inventory"),
        ('{"servers": []}', "an inventory that is not a list"),
        ("[] []", "two inventories in one response"),
    ]:
        serve([], raw={"servers": raw})
        fails(script, url, why)
    for servers, why in [
        ([{**server(0), "name": ""}], "an empty name"),
        ([{**server(0), "name": None}], "a missing name"),
        ([{**server(0), "name": "two\nlines"}], "a name with a line break"),
        ([{**server(0), "name": "tab\there"}], "a name with a tab"),
        ([{**server(0), "name": "del\x7f"}], "a name with a control character"),
        ([{**server(0), "name": "ends\\"}], "a name ending in a backslash"),
        ([{**server(0), "id": "a b,c=d"}], "an unsafe server id"),
        ([{**server(0), "id": "__collection__"}], "the reserved collection id"),
        ([{**server(0), "id": sid(0xABC).upper()}], "an id that is not lower hex"),
        ([server(0, "one"), server(0, "two")], "one id under two names"),
        ([server(0), server(0, state="NotOk")], "one id in two states"),
        ([{**server(0), "info": None}], "a server without info"),
        (
            [
                {
                    **server(0),
                    "info": {"state": "Unknown", "send_unreachable_alerts": True},
                }
            ],
            "an unknown state",
        ),
        ([{**server(0), "info": {"state": "Ok"}}], "no unreachable alert setting"),
        (
            [{**server(0), "info": {"state": "Ok", "send_unreachable_alerts": "true"}}],
            "a setting that is not a boolean",
        ),
        (["host-0"], "an inventory entry that is not an object"),
    ]:
        serve([], servers=servers)
        fails(script, url, why)

    # A run out of time stops before its next request.
    serve([])
    fails(script, url, "a run past its deadline", KOMODO_ALERT_DEADLINE="0")

    assert Core.requests >= 200, "the fake Core was never asked"
    print("komodo-alerts: ok")


if __name__ == "__main__":
    main()
