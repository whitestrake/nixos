#!/usr/bin/env python3

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPORT_TIMEOUT_SECONDS = 240
STORE_PATH = re.compile(
    r"^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$"
)
REVISION = re.compile(r"^[0-9a-f]{40}$")


def write_report(record, namespace, name, report, proof):
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
            json.dump(
                record | proof | {"packageReport": report},
                output,
            )
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def failed(message):
    return {"status": "failed", "message": message, "diff": None}


def store_path(value):
    return isinstance(value, str) and STORE_PATH.fullmatch(value) is not None


def proof_identity():
    path = os.environ["CI_PROOF_STORE_PATH"]
    revision = os.environ["CI_PROOF_REVISION"]
    if not store_path(path) or REVISION.fullmatch(revision) is None:
        raise ValueError("invalid accepted build proof identity")
    return {"proofStorePath": path, "proofRevision": revision}


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
        proof = proof_identity()
        baseline_records = json.loads(os.environ["CI_BASELINE_RECORDS_JSON"])
        system = os.environ["CI_LANE_SYSTEM"]
        if not isinstance(baseline_records, list):
            raise ValueError("baseline CI records must be an array")
        current = {
            "attr": event["attr"],
            "kind": namespace.removesuffix("s"),
            "name": name,
            "system": system,
            "storePath": event["outputs"]["out"],
        }
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
        print(f"invalid baseline CI records: {error}", file=sys.stderr)
        return 1

    if len(baseline) != 1 or not store_path(baseline[0].get("storePath")):
        raise ValueError(
            f"expected exactly one baseline record for {system}:{event['attr']}"
        )

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
        write_report(current, namespace, name, failed("closure diff failed"), proof)
        return 0

    write_report(
        current,
        namespace,
        name,
        {"status": "success", "message": "", "diff": package_diff},
        proof,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
