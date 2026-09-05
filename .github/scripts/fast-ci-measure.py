#!/usr/bin/env python3
"""Temporary playground timing wrapper; no GitHub check or promotion writes."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def main():
    output = Path(sys.argv[1])
    assert sys.argv[2] == "--"
    output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    process = subprocess.Popen(
        sys.argv[3:], stdout=subprocess.PIPE, text=True, start_new_session=True
    )

    def stop(signum, _frame):
        os.killpg(process.pid, signum)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    first_eval = None
    events = 0
    malformed = 0
    with (output / "events.jsonl").open("w") as stream:
        for line in process.stdout:
            elapsed = time.monotonic() - started
            try:
                event = json.loads(line)
                if not isinstance(event, dict):
                    raise ValueError("non-object event")
            except (ValueError, json.JSONDecodeError):
                malformed += 1
                continue
            if event.get("type") == "EVAL" and first_eval is None:
                first_eval = elapsed
            stream.write(json.dumps({"elapsedSeconds": elapsed, "event": event}) + "\n")
            events += 1
    status = process.wait()
    result = dict(
        totalSeconds=time.monotonic() - started,
        firstEvalSeconds=first_eval,
        events=events,
        malformedEvents=malformed,
        exitCode=status,
    )
    (output / "timing.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return status or bool(malformed) or first_eval is None


if __name__ == "__main__":
    raise SystemExit(main())
