#!/usr/bin/env python3
"""Runnable smoke checks for the temporary timing wrapper."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile

wrapper = Path(__file__).with_name("fast-ci-measure.py")
with tempfile.TemporaryDirectory() as directory:
    for name, program, expected in [
        ("success", 'print(\'{"type":"EVAL"}\'); print(\'{"type":"BUILD"}\')', 0),
        ("failure", 'print(\'{"type":"EVAL"}\'); raise SystemExit(7)', 7),
        ("malformed", 'print("not json")', 1),
        ("missing", 'print(\'{"type":"BUILD"}\')', 1),
    ]:
        output = Path(directory) / name
        result = subprocess.run(
            [
                sys.executable,
                str(wrapper),
                str(output),
                "--",
                sys.executable,
                "-c",
                program,
            ],
            capture_output=True,
        )
        assert result.returncode == expected, (name, result.stderr)
        timing = json.loads((output / "timing.json").read_text())
        assert timing["totalSeconds"] >= 0
        if name == "success":
            assert timing["events"] == 2
            assert 0 <= timing["firstEvalSeconds"] <= timing["totalSeconds"]
        if name == "malformed":
            assert timing["malformedEvents"] == 1
print("Timing wrapper: four subprocess probes passed")
