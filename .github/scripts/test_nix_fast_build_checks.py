import sys
import subprocess
import unittest
from pathlib import Path

from nix_fast_build_checks import CheckPublisher, check_name, run


class FakeChecks:
    def __init__(self, fail=False):
        self.fail = fail
        self.created = []
        self.updated = []

    def create(self, **payload):
        if self.fail:
            raise RuntimeError("API unavailable")
        self.created.append(payload)
        return len(self.created)

    def update(self, check_id, **payload):
        if self.fail:
            raise RuntimeError("API unavailable")
        self.updated.append((check_id, payload))


class CheckNameTests(unittest.TestCase):
    def test_names(self):
        self.assertEqual(
            check_name("linux", "omnius"),
            "CI / nixosConfiguration omnius",
        )
        self.assertEqual(
            check_name("darwin", "andred"),
            "CI / darwinConfiguration andred",
        )
        self.assertEqual(
            check_name("linux", "check-treefmt"),
            "CI / check treefmt",
        )
        self.assertIsNone(
            check_name("linux", "deploy-health-rollback-script-x86_64-linux")
        )


class CheckPublisherTests(unittest.TestCase):
    def setUp(self):
        self.checks = FakeChecks()
        self.publisher = CheckPublisher(
            self.checks,
            "linux",
            "abc123",
            "https://github.com/example/repo/actions/runs/1/attempts/2",
            "1",
            "2",
        )

    def test_successful_lifecycle(self):
        self.publisher.handle({"type": "EVAL", "attr": "omnius", "success": True})
        self.publisher.handle({"type": "BUILD", "attr": "omnius", "success": True})

        self.assertEqual(self.checks.created[0]["status"], "in_progress")
        self.assertEqual(
            self.checks.created[0]["name"], "CI / nixosConfiguration omnius"
        )
        self.assertEqual(self.checks.updated[0][0], 1)
        self.assertEqual(self.checks.updated[0][1]["conclusion"], "success")

    def test_failed_evaluation_is_completed_directly(self):
        self.publisher.handle({"type": "EVAL", "attr": "omnius", "success": False})

        self.assertEqual(self.checks.created[0]["status"], "completed")
        self.assertEqual(self.checks.created[0]["conclusion"], "failure")
        self.assertEqual(self.checks.updated, [])

    def test_failed_build_completes_with_failure(self):
        self.publisher.handle({"type": "EVAL", "attr": "omnius", "success": True})
        self.publisher.handle({"type": "BUILD", "attr": "omnius", "success": False})

        self.assertEqual(self.checks.updated[0][1]["conclusion"], "failure")

    def test_finalize_completes_dangling_checks(self):
        self.publisher.handle({"type": "EVAL", "attr": "omnius", "success": True})
        self.publisher.finalize("cancelled")

        self.assertEqual(self.checks.updated[0][1]["conclusion"], "cancelled")


class RunTests(unittest.TestCase):
    def test_cli_strips_command_separator(self):
        result = subprocess.run(
            [
                sys.executable,
                Path(__file__).with_name("nix_fast_build_checks.py"),
                "--group",
                "linux",
                "--",
                sys.executable,
                "-c",
                "raise SystemExit(0)",
            ],
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_api_failure_does_not_change_child_status(self):
        publisher = CheckPublisher(
            FakeChecks(fail=True),
            "linux",
            "abc123",
            "https://github.com/example/repo/actions/runs/1/attempts/2",
            "1",
            "2",
        )
        command = [
            sys.executable,
            "-c",
            'print(\'{"type":"EVAL","attr":"omnius","success":true}\'); raise SystemExit(7)',
        ]

        self.assertEqual(run(command, publisher), 7)


if __name__ == "__main__":
    unittest.main()
