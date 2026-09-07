#!/usr/bin/env python3
"""Validate and retain the small hosted Darwin fault evidence contract."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


gh_api_allows_escapes = None


def require(value, message):
    if not value:
        raise RuntimeError(message)


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    Path(path).write_text(
        json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n"
    )


def transactions(path):
    found = []
    for line in Path(path).read_text(errors="replace").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and set(value) == {
            "attempt",
            "status",
            "cacheFault",
            "durationSeconds",
        }:
            found.append(value)
    return found


def process_rows():
    output = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pgid=,stat="],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    result = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 4:
            result.append(
                {
                    "pid": int(fields[0]),
                    "ppid": int(fields[1]),
                    "pgid": int(fields[2]),
                    "stat": fields[3],
                }
            )
    return result


def check_dead(observer):
    rows = process_rows()
    pids = {observer["helperPid"], *observer.get("cachixPids", [])}
    pgids = {observer.get("workloadPgid"), observer.get("nfbPgid")} - {None}
    survivors = [
        row
        for row in rows
        if (row["pid"] in pids or row["pgid"] in pgids)
        and not row["stat"].startswith("Z")
    ]
    require(not survivors, f"owned attempt-one processes survived: {survivors}")


def check_runs(expected):
    command = [
        "gh",
        "api",
        "--paginate",
        "--slurp",
        "-H",
        "Accept: application/vnd.github+json",
        f"repos/{os.environ['GITHUB_REPOSITORY']}/commits/{os.environ['GITHUB_SHA']}/check-runs?filter=all&per_page=100",
    ]
    prefix = f"nfb:{os.environ['GITHUB_RUN_ID']}:{os.environ['GITHUB_RUN_ATTEMPT']}:"
    runs = []
    for _ in range(20):
        pages = json.loads(
            subprocess.run(command, check=True, capture_output=True, text=True).stdout
        )
        runs = [
            run
            for page in pages
            for run in page["check_runs"]
            if (run.get("external_id") or "").startswith(prefix)
        ]
        matching = [
            run
            for run in runs
            if run.get("external_id") in {prefix + attr for attr in expected}
        ]
        if len(matching) >= len(expected) and all(
            run.get("status") == "completed" for run in matching
        ):
            break
        time.sleep(0.5)
    sanitised = [
        {
            key: run.get(key)
            for key in ("id", "name", "head_sha", "status", "conclusion", "external_id")
        }
        for run in runs
    ]
    write(Path(os.environ["EVIDENCE"]) / "check-runs.json", sanitised)
    grouped = {
        attr: [run for run in runs if run.get("external_id") == prefix + attr]
        for attr in expected
    }
    require(set(expected) == set(grouped), "internal expected check identity mismatch")
    require(
        all(len(grouped[attr]) == 1 for attr in expected),
        "expected exactly one Check Run per attr",
    )
    return {attr: grouped[attr][0] for attr in expected}


def gh_json(endpoint, *, paginate=False):
    command = ["gh", "api"]
    if paginate:
        command.extend(("--paginate", "--slurp"))
    command.extend(("-H", "Accept: application/vnd.github+json", endpoint))
    return json.loads(
        subprocess.run(command, check=True, capture_output=True, text=True).stdout
    )


def gh_log(endpoint):
    global gh_api_allows_escapes
    if gh_api_allows_escapes is None:
        help_result = subprocess.run(
            ["gh", "api", "--help"], capture_output=True, text=True
        )
        gh_api_allows_escapes = (
            help_result.returncode == 0
            and "--allow-escape-sequences" in help_result.stdout
        )
    options = ["--allow-escape-sequences"] if gh_api_allows_escapes else []
    result = subprocess.run(
        ["gh", "api", *options, "-H", "Accept: application/vnd.github+json", endpoint],
        check=True,
        capture_output=True,
    )
    return result.stdout.decode(errors="replace")


def embedded_json(log):
    decoder = json.JSONDecoder()
    values = []
    for line in log.splitlines():
        for index, character in enumerate(line):
            if character != "{":
                continue
            try:
                value, _ = decoder.raw_decode(line[index:])
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                values.append(value)
                break
    return values


def authenticate_control(run_id, release_id, proof_store_path, evidence):
    repository = os.environ["GITHUB_REPOSITORY"]
    head_sha = os.environ["GITHUB_SHA"]
    run = gh_json(f"repos/{repository}/actions/runs/{run_id}")
    require(run.get("id") == run_id, "control run ID mismatch")
    require(
        run.get("repository", {}).get("full_name") == repository,
        "control run repository mismatch",
    )
    require(
        run.get("head_repository", {}).get("full_name") == repository,
        "control run head repository mismatch",
    )
    require(
        run.get("head_sha") == head_sha, "control run is not from this harness head"
    )
    require(
        run.get("path") == ".github/workflows/continuous-integration.yml",
        "control is not ordinary CI",
    )
    require(
        run.get("event") in ("push", "workflow_dispatch"),
        "control run event is not ordinary",
    )
    require(
        run.get("status") == "completed" and run.get("conclusion") == "success",
        "control run did not succeed",
    )
    attempt = run.get("run_attempt")
    require(isinstance(attempt, int) and attempt > 0, "control run attempt is invalid")

    pages = gh_json(
        f"repos/{repository}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100",
        paginate=True,
    )
    jobs = [job for page in pages for job in page.get("jobs", [])]
    selected_jobs = {}
    for name in ("Darwin", "All Builds"):
        matches = [job for job in jobs if job.get("name") == name]
        require(len(matches) == 1, f"control run did not have exactly one {name} job")
        job = matches[0]
        require(
            job.get("status") == "completed" and job.get("conclusion") == "success",
            f"control {name} job did not succeed",
        )
        selected_jobs[name] = job

    darwin_log = gh_log(
        f"repos/{repository}/actions/jobs/{selected_jobs['Darwin']['id']}/logs"
    )
    selections = [
        value
        for value in embedded_json(darwin_log)
        if set(("releaseId", "revision", "components")).issubset(value)
    ]
    require(
        len(selections) == 1,
        "Darwin control log did not contain exactly one cache selection",
    )
    selection = selections[0]
    require(
        selection.get("releaseId") == release_id,
        "Darwin control selected a different Release ID",
    )
    require(
        isinstance(selection.get("revision"), str),
        "Darwin control selection revision is invalid",
    )

    aggregate_log = gh_log(
        f"repos/{repository}/actions/jobs/{selected_jobs['All Builds']['id']}/logs"
    )
    marker = "Published durable CI build proof: "
    proof_paths = [
        line.split(marker, 1)[1].strip()
        for line in aggregate_log.splitlines()
        if marker in line
    ]
    proof_paths = [
        path
        for path in proof_paths
        if path.startswith("/nix/store/") and path.endswith("-ci-build-proof.json")
    ]
    require(
        proof_paths == [proof_store_path],
        "All Builds control log did not publish the supplied proof path",
    )

    provenance = {
        "runId": run_id,
        "runAttempt": attempt,
        "repository": repository,
        "headSha": head_sha,
        "workflowPath": run["path"],
        "event": run["event"],
        "status": run["status"],
        "conclusion": run["conclusion"],
        "jobs": {
            name: {
                "id": job["id"],
                "name": name,
                "status": job["status"],
                "conclusion": job["conclusion"],
            }
            for name, job in selected_jobs.items()
        },
        "selection": {
            "releaseId": selection["releaseId"],
            "revision": selection["revision"],
        },
        "proof": {"storePath": proof_store_path},
    }
    write(evidence / "control-provenance.json", provenance)


def initial(case, state, evidence, release_id):
    selection = read(state / "selection.json")
    require(
        selection["generation"]["releaseId"] == release_id,
        "selection Release ID mismatch",
    )
    setup = read(state / "setup-recovery.json")
    if case != "setup":
        require(
            setup == {"recovered": False},
            "prepare-time recovery makes this case invalid",
        )
        if case == "loss":
            require(
                read(evidence / "observer-result.json")["initialMode"]["mode"] == "hot",
                "case did not start on a hot mount",
            )
        else:
            require(
                read(state / "mode.json")["mode"] == "hot",
                "case did not start on a hot mount",
            )
    write(
        evidence / "initial-mount.json",
        {
            "mode": "hot",
            "releaseId": release_id,
            "selectionReleaseId": selection["generation"]["releaseId"],
        },
    )


def verify_loss(state, evidence, release_id, control_run_id, control_proof_store_path):
    initial("loss", state, evidence, release_id)
    tx = transactions(evidence / "transaction.log")
    require(
        len(tx) == 2
        and tx[0]["attempt"] == 1
        and tx[0]["status"] != 0
        and tx[0]["cacheFault"] == "helper-exited"
        and tx[1]["attempt"] == 2
        and tx[1]["status"] == 0
        and tx[1]["cacheFault"] is None,
        "runtime recovery transaction did not have the required two attempts",
    )
    observer = read(evidence / "observer-result.json")
    require(
        observer.get("outcome") == "faulted" and observer.get("phase") == "runtime",
        "runtime observer was inconclusive",
    )
    require(observer["nfbPid"] == observer["nfbPgid"], "NFB was not its session leader")
    require(
        observer.get("sawEvaluator") or observer.get("sawCachix"),
        "no NFB child workload process was observed",
    )
    require(
        observer["initialMode"]["mode"] == "hot"
        and observer["releaseId"] == release_id,
        "fault did not target the pinned hot mount",
    )
    check_dead(observer)
    require(not (state / "attempt-1").exists(), "discarded attempt one remains")
    selected = state / "selected"
    for name in ("results.json", "records.json", "checks.json"):
        require((selected / name).is_file(), f"missing selected {name}")
    require(
        read(state / "mode.json")["mode"] == "maintenance",
        "recovery did not select maintenance mode",
    )
    require(
        read(state / "selection.json")["generation"]["releaseId"] == release_id,
        "recovery changed Release ID",
    )

    authenticate_control(control_run_id, release_id, control_proof_store_path, evidence)
    control = read(evidence / "control-proof.json")
    require(
        control["revision"] == os.environ["GITHUB_SHA"],
        "control proof is not from this harness head",
    )
    records = read(selected / "records.json")
    actual = sorted(
        ({"attr": row["attr"], "storePath": row["storePath"]} for row in records),
        key=lambda row: row["attr"],
    )
    expected = sorted(
        (
            {"attr": row["attr"], "storePath": row["storePath"]}
            for row in control["records"]
            if row["system"] == "aarch64-darwin"
        ),
        key=lambda row: row["attr"],
    )
    require(actual == expected, "selected Darwin mapping differs from control")
    candidate = {
        "revision": os.environ["GITHUB_SHA"],
        "records": [
            row for row in control["records"] if row["system"] != "aarch64-darwin"
        ]
        + [
            {
                "attr": row["attr"],
                "system": "aarch64-darwin",
                "storePath": row["storePath"],
            }
            for row in records
        ],
    }
    canonical = subprocess.run(
        ["jq", "-ceS", "-f", ".github/scripts/ci-build-proof.jq"],
        input=json.dumps(candidate),
        check=True,
        capture_output=True,
        text=True,
    ).stdout.encode()
    (evidence / "recovered-proof.json").write_bytes(canonical)
    require(
        (evidence / "control-proof.json").read_bytes() == canonical,
        "recovered proof bytes differ from control",
    )

    checks = read(selected / "checks.json")
    require(
        checks.get("conclusion") == "success",
        "selected deferred check journal was not successful",
    )
    run_map = check_runs([row["attr"] for row in records])
    require(
        all(
            run["status"] == "completed" and run["conclusion"] == "success"
            for run in run_map.values()
        ),
        "selected Check Runs were not uniquely successful",
    )
    for name in ("records.json", "results.json", "checks.json"):
        shutil.copyfile(selected / name, evidence / f"selected-{name}")
    write(evidence / "transactions.json", tx)


def verify_failure(state, evidence, release_id):
    initial("failure", state, evidence, release_id)
    tx = transactions(evidence / "transaction.log")
    require(
        len(tx) == 1
        and tx[0]["attempt"] == 1
        and tx[0]["status"] != 0
        and tx[0]["cacheFault"] is None,
        "genuine failure was retried or classified as a cache fault",
    )
    attempt = state / "attempt-1"
    require(
        attempt.is_dir()
        and not (state / "attempt-2").exists()
        and not (state / "selected").exists(),
        "genuine failure state was selected or retried",
    )
    helper = read(state / "helper.json")["pid"]
    live = [
        row
        for row in process_rows()
        if row["pid"] == helper and not row["stat"].startswith("Z")
    ]
    require(
        len(live) == 1, "original helper did not remain live through genuine failure"
    )
    checks = read(attempt / "checks.json")
    events = [
        event
        for event in checks.get("events", [])
        if event.get("attr") == "intentional" and event.get("type") in ("EVAL", "BUILD")
    ]
    require(
        checks.get("conclusion") == "failure"
        and len(events) == 2
        and events[0].get("type") == "EVAL"
        and events[0].get("success") is True
        and events[1].get("type") == "BUILD"
        and events[1].get("success") is False,
        "intentional derivation did not produce one successful EVAL and one failed BUILD",
    )
    results = read(attempt / "results.json")
    result_events = [
        event
        for event in results.get("results", [])
        if event.get("attr") == "intentional" and event.get("type") in ("EVAL", "BUILD")
    ]
    require(
        len(result_events) == 2
        and result_events[0].get("type") == "EVAL"
        and result_events[0].get("success") is True
        and result_events[1].get("type") == "BUILD"
        and result_events[1].get("success") is False,
        "result journal does not contain the intentional EVAL/BUILD failure pair",
    )
    run = check_runs(["intentional"])["intentional"]
    require(
        run["status"] == "completed" and run["conclusion"] == "failure",
        "intentional Check Run was not failed",
    )
    for name in ("results.json", "checks.json"):
        shutil.copyfile(attempt / name, evidence / f"attempt-1-{name}")
    shutil.copyfile(
        Path(os.environ["RUNNER_TEMP"]) / "failure/flake.nix",
        evidence / "intentional-failure.flake.nix",
    )
    write(evidence / "transactions.json", tx)


def verify_setup(state, evidence, release_id):
    selection = read(state / "selection.json")
    require(
        selection["generation"]["releaseId"] == release_id,
        "selection Release ID mismatch",
    )
    observer = read(evidence / "observer-result.json")
    require(
        observer.get("outcome") == "faulted" and observer.get("phase") == "setup",
        "setup observer was inconclusive",
    )
    require(
        observer["initialMode"]["mode"] == "hot"
        and observer["releaseId"] == release_id,
        "setup fault did not target the pinned hot mount",
    )
    recovery = read(state / "setup-recovery.json")
    require(
        recovery == {"recovered": True, "cacheFault": "helper-exited"},
        "ordinary prepare did not perform one setup recovery",
    )
    require(
        read(state / "mode.json")["mode"] == "maintenance",
        "setup recovery did not use maintenance mode",
    )
    require(
        not any(
            (state / name).exists() for name in ("attempt-1", "attempt-2", "selected")
        ),
        "setup recovery unexpectedly entered runtime transaction",
    )
    dead = not [
        row
        for row in process_rows()
        if row["pid"] == observer["helperPid"] and not row["stat"].startswith("Z")
    ]
    require(dead, "faulted setup helper survived")
    write(
        evidence / "initial-mount.json",
        {"mode": "hot", "releaseId": release_id, "selectionReleaseId": release_id},
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case", choices=("loss", "failure", "setup"))
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--release-id", required=True, type=int)
    parser.add_argument("--control-run-id", type=int)
    parser.add_argument("--control-proof-store-path")
    args = parser.parse_args()
    os.environ["EVIDENCE"] = str(args.evidence)
    if args.case == "loss":
        if not args.control_run_id or not args.control_proof_store_path:
            parser.error(
                "loss requires --control-run-id and --control-proof-store-path"
            )
        verify_loss(
            args.state,
            args.evidence,
            args.release_id,
            args.control_run_id,
            args.control_proof_store_path,
        )
    else:
        {"failure": verify_failure, "setup": verify_setup}[args.case](
            args.state, args.evidence, args.release_id
        )
    write(args.evidence / "verification.json", {"case": args.case, "status": "passed"})


if __name__ == "__main__":
    main()
