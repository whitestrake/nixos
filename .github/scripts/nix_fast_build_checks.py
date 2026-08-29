#!/usr/bin/env python3

import argparse
import json
import os
import signal
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def check_name(group, attr):
    if attr.startswith("deploy-health-rollback-script-"):
        return None
    if attr.startswith("check-"):
        return f"CI / check {attr.removeprefix('check-')}"
    kind = {
        "linux": "nixosConfiguration",
        "darwin": "darwinConfiguration",
    }[group]
    return f"CI / {kind} {attr}"


class GitHubChecks:
    def __init__(self, token, repository, api_url="https://api.github.com"):
        self.token = token
        self.repository = repository
        self.api_url = api_url.rstrip("/")
        self.disabled = not token or not repository
        self.warned = False
        if self.disabled:
            self._warn("GitHub check publication disabled: missing repository or token")

    def _warn(self, message):
        if not self.warned:
            print(f"::warning::{message}", file=sys.stderr)
            self.warned = True

    def _request(self, method, path, payload):
        if self.disabled:
            return None

        request = urllib.request.Request(
            f"{self.api_url}{path}",
            data=json.dumps(payload).encode(),
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        attempts = 1 if method == "POST" else 3
        for attempt in range(attempts):
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    return json.load(response)
            except OSError as error:
                if attempt + 1 < attempts:
                    retry_after = (getattr(error, "headers", None) or {}).get(
                        "Retry-After"
                    )
                    try:
                        delay = float(retry_after)
                    except (TypeError, ValueError):
                        delay = 2 ** (attempt + 1)
                    delay = min(max(delay, 0.0), 4.0)
                    time.sleep(delay)
                    continue
                self.disabled = True
                self._warn(
                    f"GitHub check publication disabled after API failure: {error}"
                )
        return None

    def create(self, **payload):
        response = self._request(
            "POST", f"/repos/{self.repository}/check-runs", payload
        )
        return response.get("id") if response else None

    def update(self, check_id, **payload):
        return self._request(
            "PATCH",
            f"/repos/{self.repository}/check-runs/{check_id}",
            payload,
        )


class CheckPublisher:
    def __init__(self, checks, group, head_sha, details_url, run_id, attempt):
        self.checks = checks
        self.group = group
        self.head_sha = head_sha
        self.details_url = details_url
        self.run_id = run_id
        self.attempt = attempt
        self.outstanding = {}
        self.seen = set()
        self.warned = False

    def _call(self, method, *args, **kwargs):
        try:
            return method(*args, **kwargs)
        except Exception as error:
            if not self.warned:
                print(
                    f"::warning::GitHub check publication failed: {error}",
                    file=sys.stderr,
                )
                self.warned = True
            return None

    def _completed(self, attr, conclusion, summary):
        return {
            "name": check_name(self.group, attr),
            "head_sha": self.head_sha,
            "status": "completed",
            "conclusion": conclusion,
            "completed_at": now(),
            "external_id": (f"nfb:{self.run_id}:{self.attempt}:{self.group}:{attr}"),
            "details_url": self.details_url,
            "output": {
                "title": f"{attr}: {conclusion}",
                "summary": summary,
            },
        }

    def handle(self, event):
        event_type = event.get("type")
        attr = event.get("attr")
        if event_type not in {"EVAL", "BUILD"} or not isinstance(attr, str):
            return
        if check_name(self.group, attr) is None:
            return

        success = event.get("success") is True
        if event_type == "EVAL":
            if attr in self.seen:
                return
            self.seen.add(attr)
            if success:
                check_id = self._call(
                    self.checks.create,
                    name=check_name(self.group, attr),
                    head_sha=self.head_sha,
                    status="in_progress",
                    started_at=now(),
                    external_id=(
                        f"nfb:{self.run_id}:{self.attempt}:{self.group}:{attr}"
                    ),
                    details_url=self.details_url,
                )
                if check_id is not None:
                    self.outstanding[attr] = check_id
            else:
                self._call(
                    self.checks.create,
                    **self._completed(attr, "failure", "Nix evaluation failed."),
                )
            return

        check_id = self.outstanding.get(attr)
        if check_id is not None:
            conclusion = "success" if success else "failure"
            payload = self._completed(
                attr,
                conclusion,
                "Nix build succeeded." if success else "Nix build failed.",
            )
            payload.pop("name")
            payload.pop("head_sha")
            payload.pop("external_id")
            payload.pop("details_url")
            if self._call(self.checks.update, check_id, **payload) is not None:
                self.outstanding.pop(attr, None)

    def finalize(self, conclusion):
        summary = (
            "Nix Fast Build completed successfully without a build event."
            if conclusion == "success"
            else "Nix Fast Build exited before this output completed."
        )
        for attr, check_id in list(self.outstanding.items()):
            payload = self._completed(
                attr,
                conclusion,
                summary,
            )
            payload.pop("name")
            payload.pop("head_sha")
            payload.pop("external_id")
            payload.pop("details_url")
            if self._call(self.checks.update, check_id, **payload) is not None:
                self.outstanding.pop(attr, None)


def run(command, publisher):
    process = subprocess.Popen(
        [*command, "--stream-json-lines"],
        stdout=subprocess.PIPE,
        text=True,
    )
    interrupted = False
    previous_handlers = {}

    def forward(signum, _frame):
        nonlocal interrupted
        interrupted = True
        if process.poll() is None:
            process.send_signal(signum)

    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[signum] = signal.signal(signum, forward)
        assert process.stdout is not None
        with process.stdout:
            for line in process.stdout:
                try:
                    publisher.handle(json.loads(line))
                except json.JSONDecodeError:
                    print(
                        "::warning::Ignoring malformed nix-fast-build event",
                        file=sys.stderr,
                    )
        return_code = process.wait()
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)

    conclusion = (
        "cancelled" if interrupted else "success" if return_code == 0 else "failure"
    )
    publisher.finalize(conclusion)
    return return_code


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--group", choices=("linux", "darwin"), required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a nix-fast-build command is required after --")

    repository = os.environ.get("GITHUB_REPOSITORY", "")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
    server_url = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    publisher = CheckPublisher(
        GitHubChecks(
            os.environ.get("GITHUB_TOKEN", ""),
            repository,
            os.environ.get("GITHUB_API_URL", "https://api.github.com"),
        ),
        args.group,
        os.environ.get("GITHUB_SHA", ""),
        f"{server_url}/{repository}/actions/runs/{run_id}/attempts/{attempt}",
        run_id,
        attempt,
    )
    return_code = run(args.command, publisher)
    if return_code < 0:
        os.kill(os.getpid(), -return_code)
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
