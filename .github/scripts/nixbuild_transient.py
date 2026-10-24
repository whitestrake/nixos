#!/usr/bin/env python3
"""Tell nixbuild.net's opaque build errors apart from real Linux build failures.

nixbuild.net sometimes fails a remote build after minutes of silence with nothing
but `error: error <uuid>`, and the same build passes a few minutes later. A real
failure always carries Nix's own diagnostics (`builder for ... failed`, `Cannot
build ...`), so a host counts as transient only when every error line it logged
is the opaque kind. Prints the transient hosts, or nothing when any failure is real.
"""

import argparse
import json
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
# nix-fast-build prefixes each build's output with its attribute.
LINE = re.compile(r"^(?P<attr>[\w.-]+)> (?P<message>.*)$")
OPAQUE = re.compile(r"^error: error [0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$")


def failed_builds(results):
    """Attributes whose builds failed, or None if anything else failed."""
    succeeded = {
        result.get("attr")
        for result in results
        if result.get("type") == "BUILD" and result.get("success") is True
    }
    failed = set()
    for result in results:
        if result.get("success") is True:
            continue
        if result.get("type") != "BUILD" or not isinstance(result.get("attr"), str):
            return None
        failed.add(result["attr"])
    return sorted(failed - succeeded)


def error_lines(log):
    found = {}
    for raw in log.splitlines():
        match = LINE.match(ANSI.sub("", raw).rstrip())
        if match and match["message"].startswith("error:"):
            found.setdefault(match["attr"], []).append(match["message"])
    return found


def transient_hosts(results, log):
    failed = failed_builds(results)
    if not failed:
        return []
    errors = error_lines(log)
    for attr in failed:
        lines = errors.get(attr)
        if not lines or not all(OPAQUE.match(line) for line in lines):
            return []
    return failed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("results", help="nix-fast-build --result-file output")
    parser.add_argument("log", help="nix-fast-build's combined output")
    args = parser.parse_args()
    with open(args.results) as stream:
        results = json.load(stream).get("results", [])
    with open(args.log, errors="replace") as stream:
        log = stream.read()
    for attr in transient_hosts(results, log):
        print(attr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
