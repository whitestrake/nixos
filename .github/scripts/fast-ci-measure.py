#!/usr/bin/env python3
"""Temporary timing wrapper, optionally forwarding events to the normal publisher."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


def read_mem_available(path):
    for line in path.read_text().splitlines():
        fields = line.split()
        if fields[:1] == ["MemAvailable:"]:
            if len(fields) != 3 or fields[2] != "kB":
                raise ValueError("unexpected MemAvailable format")
            return int(fields[1])
    raise ValueError("MemAvailable is missing")


def main():
    output = Path(sys.argv[1])
    assert sys.argv[2] == "--"
    output.mkdir(parents=True, exist_ok=True)
    meminfo = Path("/proc/meminfo")
    memory_samples = []
    memory_stop = None
    memory_thread = None
    if os.environ.get("FAST_CI_SAMPLE_MEMORY") == "1":
        memory_samples.append(read_mem_available(meminfo))
        memory_stop = threading.Event()

        def sample_memory():
            while not memory_stop.wait(1):
                memory_samples.append(read_mem_available(meminfo))

        memory_thread = threading.Thread(target=sample_memory, daemon=True)

    started = time.monotonic()
    process = subprocess.Popen(
        sys.argv[3:], stdout=subprocess.PIPE, text=True, start_new_session=True
    )
    if memory_thread is not None:
        memory_thread.start()

    def stop(signum, _frame):
        os.killpg(process.pid, signum)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    first_eval = None
    events = 0
    malformed = 0
    forward_events = os.environ.get("FAST_CI_FORWARD_EVENTS") == "1"
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
            if forward_events:
                print(line, end="", flush=True)
            events += 1
    status = process.wait()
    if memory_thread is not None:
        memory_stop.set()
        memory_thread.join()
        memory_samples.append(read_mem_available(meminfo))
        baseline = memory_samples[0]
        minimum = min(memory_samples)
        memory = {
            "scope": "whole Linux runner",
            "source": "/proc/meminfo MemAvailable",
            "unit": "KiB",
            "sampleIntervalSeconds": 1,
            "samples": len(memory_samples),
            "baselineMemAvailableKiB": baseline,
            "minimumMemAvailableKiB": minimum,
            "maximumRunnerMemoryUseAboveBaselineKiB": max(0, baseline - minimum),
        }
        (output / "runner-memory.json").write_text(json.dumps(memory, indent=2) + "\n")
    result = dict(
        totalSeconds=time.monotonic() - started,
        firstEvalSeconds=first_eval,
        events=events,
        malformedEvents=malformed,
        exitCode=status,
    )
    (output / "timing.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), file=sys.stderr if forward_events else sys.stdout)
    return status or bool(malformed) or first_eval is None


if __name__ == "__main__":
    raise SystemExit(main())
