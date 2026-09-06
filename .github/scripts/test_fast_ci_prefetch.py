#!/usr/bin/env python3
"""Small offline check of the experimental prefetch boundary and hash guard."""

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "prefetch", Path(__file__).with_name("fast-ci-prefetch.py")
)
prefetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prefetch)
locked = dict(
    type="github",
    owner="NixOS",
    repo="nixpkgs",
    rev="a" * 40,
    narHash="sha256-" + "A" * 43 + "=",
)
assert "%3D" in prefetch.reference(locked)
for change in (
    dict(type="path"),
    dict(owner="other"),
    dict(rev="HEAD"),
    dict(narHash="bad"),
):
    try:
        prefetch.reference(locked | change)
    except ValueError:
        pass
    else:
        raise AssertionError(change)
with tempfile.TemporaryDirectory() as directory:
    previous = Path.cwd()
    try:
        os.chdir(directory)
        inputs = {
            name: name for name in ("nixpkgs", "nixpkgs-darwin", "nixpkgs-unstable")
        }
        Path("flake.lock").write_text(
            json.dumps(
                dict(
                    root="root",
                    nodes={"root": dict(inputs=inputs)}
                    | {name: dict(locked=locked) for name in inputs},
                )
            )
        )
        for mode in ("serial", "parallel"):
            with (
                patch.object(sys, "argv", ["prefetch", "result.json", mode]),
                patch.object(
                    prefetch.subprocess,
                    "check_output",
                    return_value=json.dumps(dict(hash=locked["narHash"])),
                ) as command,
            ):
                prefetch.main()
                assert command.call_count == 3
                assert len(json.loads(Path("result.json").read_text())["inputs"]) == 3
        with (
            patch.object(sys, "argv", ["prefetch", "result.json", "parallel"]),
            patch.object(
                prefetch.subprocess, "check_output", return_value='{"hash":"wrong"}'
            ),
        ):
            try:
                prefetch.main()
            except ValueError:
                pass
            else:
                raise AssertionError("wrong input hash accepted")
    finally:
        os.chdir(previous)
print("Prefetch input validation, both modes and hash rejection passed")
