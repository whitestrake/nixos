#!/usr/bin/env python3

import json
import os
import subprocess
import sys
from pathlib import Path


def write_report(record, namespace, name, report):
    path = (
        Path(os.environ["CI_PACKAGE_REPORT_DIR"])
        / os.environ["CI_LANE_SYSTEM"]
        / namespace
        / name
        / "record.json"
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record | {"packageReport": report}) + "\n")


def failed(message):
    return {"status": "failed", "message": message, "diff": None}


def main():
    try:
        event = json.load(sys.stdin)
        if (
            not isinstance(event, dict)
            or event.get("type") != "BUILD"
            or event.get("success") is not True
            or not isinstance(event.get("attr"), str)
            or not isinstance(event.get("outputs"), dict)
            or not isinstance(event["outputs"].get("out"), str)
        ):
            raise ValueError("expected one successful BUILD event")
        namespace, name = event["attr"].split(".")
        if (
            namespace not in {"nixosConfigurations", "darwinConfigurations", "checks"}
            or not name
            or "/" in name
        ):
            raise ValueError("unsafe BUILD attribute")
    except (json.JSONDecodeError, TypeError, ValueError) as error:
        print(f"invalid nix-fast-build event: {error}", file=sys.stderr)
        return 1

    if namespace == "checks":
        return 0

    try:
        current_records = json.loads(os.environ["CI_CURRENT_RECORDS_JSON"])
        baseline_records = json.loads(os.environ["CI_BASELINE_RECORDS_JSON"])
        system = os.environ["CI_LANE_SYSTEM"]
        current = [
            record
            for record in current_records
            if record.get("system") == system and record.get("attr") == event["attr"]
        ]
        if len(current) != 1 or current[0].get("storePath") != event["outputs"]["out"]:
            raise ValueError("missing current record for BUILD event")
        baseline = [
            record
            for record in baseline_records
            if record.get("system") == system and record.get("attr") == event["attr"]
        ]
    except (
        AttributeError,
        KeyError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
    ) as error:
        print(f"invalid CI records: {error}", file=sys.stderr)
        return 1

    if len(baseline) != 1:
        write_report(
            current[0], namespace, name, failed("baseline artifact unavailable")
        )
        return 0

    try:
        realised = subprocess.run(
            ["nix-store", "--realise", baseline[0]["storePath"]],
            stdout=subprocess.DEVNULL,
            timeout=240,
            check=False,
        )
    except (KeyError, OSError, subprocess.TimeoutExpired):
        realised = None
    if realised is None or realised.returncode != 0:
        write_report(
            current[0],
            namespace,
            name,
            failed("baseline closure did not realise within 4m"),
        )
        return 0

    try:
        diff = subprocess.run(
            [
                os.environ["DIX_BIN"],
                "--color",
                "never",
                "--output",
                "json",
                baseline[0]["storePath"],
                event["outputs"]["out"],
            ],
            stdout=subprocess.PIPE,
            text=True,
            check=False,
        )
        if diff.returncode != 0:
            raise ValueError
        package_diff = json.loads(diff.stdout)
    except (KeyError, OSError, ValueError, json.JSONDecodeError):
        write_report(current[0], namespace, name, failed("closure diff failed"))
        return 0

    write_report(
        current[0],
        namespace,
        name,
        {"status": "success", "message": "", "diff": package_diff},
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
