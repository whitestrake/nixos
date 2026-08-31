#!/usr/bin/env python3

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPORT_TIMEOUT_SECONDS = 240
STORE_PATH = re.compile(r"^/nix/store/[0-9a-z]{32}-[A-Za-z0-9+._?=-]+$")


def write_report(record, namespace, name, report):
    path = (
        Path(os.environ["CI_PACKAGE_REPORT_DIR"])
        / os.environ["CI_LANE_SYSTEM"]
        / namespace
        / name
        / "record.json"
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as output:
            temporary = Path(output.name)
            json.dump(record | {"packageReport": report}, output)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def failed(message):
    return {"status": "failed", "message": message, "diff": None}


def store_path(value):
    return isinstance(value, str) and STORE_PATH.fullmatch(value) is not None


def main():
    try:
        event = json.load(sys.stdin)
        if (
            not isinstance(event, dict)
            or event.get("type") != "BUILD"
            or event.get("success") is not True
            or not isinstance(event.get("attr"), str)
            or not isinstance(event.get("outputs"), dict)
            or not store_path(event["outputs"].get("out"))
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
        if (
            len(current) != 1
            or not store_path(current[0].get("storePath"))
            or current[0]["storePath"] != event["outputs"]["out"]
        ):
            raise ValueError("missing current record for BUILD event")
        baseline = [
            record
            for record in baseline_records
            if isinstance(record, dict)
            and record.get("system") == system
            and record.get("attr") == event["attr"]
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

    if len(baseline) != 1 or not store_path(baseline[0].get("storePath")):
        write_report(
            current[0], namespace, name, failed("baseline artifact unavailable")
        )
        return 0

    try:
        realised = subprocess.run(
            [
                "nix-store",
                "--realise",
                "--option",
                "builders",
                "",
                "--option",
                "max-jobs",
                "0",
                baseline[0]["storePath"],
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=REPORT_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        realised = None
        detail = error.stderr or ""
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        detail = " ".join(detail.split())[:1000]
        message = "baseline closure realisation timed out after 4m"
        if detail:
            message += f": {detail}"
    except (KeyError, OSError) as error:
        realised = None
        message = f"baseline closure realisation failed: {str(error)[:1000]}"
    if realised is not None and realised.returncode != 0:
        detail = " ".join((realised.stderr or "").split())[:1000]
        message = "baseline closure realisation failed"
        if detail:
            message += f": {detail}"
    if realised is None or realised.returncode != 0:
        write_report(
            current[0],
            namespace,
            name,
            failed(message),
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
            timeout=REPORT_TIMEOUT_SECONDS,
            check=False,
        )
        if diff.returncode != 0:
            raise ValueError
        package_diff = json.loads(diff.stdout)
    except (
        KeyError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        subprocess.TimeoutExpired,
    ):
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
