#!/usr/bin/env python3
"""Focused, portable checks for package report collection and rendering."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def module(name):
    spec = importlib.util.spec_from_file_location(
        name, Path(__file__).with_name(name + ".py")
    )
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


collector = module("nix_fast_build_package_report")
renderer = module("flake_lock_package_report")
BASE = "a" * 40
HEAD = "b" * 40
OLD = "/nix/store/" + "0" * 32 + "-old"
NEW = "/nix/store/" + "1" * 32 + "-new"
EVENT = {
    "type": "BUILD",
    "success": True,
    "attr": "nixosConfigurations.host",
    "outputs": {"out": NEW},
}


class PackageReportChecks(unittest.TestCase):
    def test_mixed_pairs_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            for index, base in enumerate((BASE, "c" * 40)):
                path = Path(directory, str(index), "record.json")
                path.parent.mkdir()
                path.write_text(
                    json.dumps(
                        {
                            "name": "host",
                            "system": "x86_64-linux",
                            "baseSha": base,
                            "headSha": HEAD,
                            "packageReport": {
                                "status": "success",
                                "message": "",
                                "diff": {"diffs": []},
                            },
                        }
                    )
                )
            with self.assertRaisesRegex(SystemExit, "mixed base/head pairs"):
                renderer.load_reports(directory)

    def test_fragment_text_cannot_create_markdown(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "record.json")
            path.write_text(
                json.dumps(
                    {
                        "name": "host\n## forged heading",
                        "system": "x86_64-linux",
                        "baseSha": BASE,
                        "headSha": HEAD,
                        "packageReport": {
                            "status": "failed",
                            "message": "<script>surprise</script>",
                            "diff": None,
                        },
                    }
                )
            )
            rendered = renderer.render(directory, BASE, HEAD)
            self.assertNotIn("\n## forged heading", rendered)
            self.assertNotIn("<script>", rendered)

    def test_cached_base_skips_copy_and_build(self):
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            return type("Result", (), {"returncode": 0, "stdout": ""})()

        with (
            patch.object(collector.subprocess, "run", side_effect=run),
            patch.object(
                collector, "cache_status", side_effect=AssertionError("cache queried")
            ),
        ):
            collector.ensure_baseline(OLD, "repo")
        self.assertEqual(calls, [["nix", "path-info", "--recursive", OLD]])

    def test_confirmed_cache_miss_builds_exact_base_path(self):
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            output = OLD + "\n" if command[1] == "build" else ""
            code = 1 if command[1] == "path-info" and len(calls) == 1 else 0
            return type(
                "Result",
                (),
                {
                    "returncode": code,
                    "stdout": output,
                    "stderr": f"error: path '{OLD}' is not valid",
                },
            )()

        with (
            patch.object(collector.subprocess, "run", side_effect=run),
            patch.object(collector, "cache_status", return_value=404),
        ):
            collector.ensure_baseline(
                OLD, "repo", "x86_64-linux", "nixosConfigurations.host"
            )
        self.assertEqual(
            calls[1],
            [
                "nix",
                "build",
                "--no-link",
                "--print-out-paths",
                ".#ci.x86_64-linux.nixosConfigurations.host",
            ],
        )

    def test_cachix_hit_copies_exact_path(self):
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            code = 1 if len(calls) == 1 else 0
            return type(
                "Result",
                (),
                {
                    "returncode": code,
                    "stdout": "",
                    "stderr": f"error: path '{OLD}' is not valid",
                },
            )()

        with (
            patch.object(collector.subprocess, "run", side_effect=run),
            patch.object(collector, "cache_status", return_value=200),
        ):
            collector.ensure_baseline(
                OLD, "repo", "x86_64-linux", "nixosConfigurations.host"
            )
        self.assertEqual(calls[1], ["nix", "copy", "--from", collector.CACHE_URL, OLD])
        self.assertFalse(any(command[1] == "build" for command in calls))

    def test_fallback_rejects_different_output(self):
        def run(command, **kwargs):
            if command[1] == "path-info":
                return type(
                    "Result",
                    (),
                    {
                        "returncode": 1,
                        "stdout": "",
                        "stderr": f"error: path '{OLD}' is not valid",
                    },
                )()
            return type(
                "Result", (), {"returncode": 0, "stdout": NEW + "\n", "stderr": ""}
            )()

        with (
            patch.object(collector.subprocess, "run", side_effect=run),
            patch.object(collector, "cache_status", return_value=404),
        ):
            with self.assertRaisesRegex(ValueError, "baseline build differs"):
                collector.ensure_baseline(
                    OLD, "repo", "x86_64-linux", "nixosConfigurations.host"
                )

    def test_cache_service_error_is_fatal(self):
        def run(command, **kwargs):
            return type(
                "Result",
                (),
                {
                    "returncode": 1,
                    "stdout": "",
                    "stderr": f"error: path '{OLD}' is not valid",
                },
            )()

        with (
            patch.object(collector.subprocess, "run", side_effect=run),
            patch.object(collector, "cache_status", return_value=503),
        ):
            with self.assertRaisesRegex(RuntimeError, "cache returned 503"):
                collector.ensure_baseline(
                    OLD, "repo", "x86_64-linux", "nixosConfigurations.host"
                )

    def test_local_store_error_is_not_a_cache_miss(self):
        def run(command, **kwargs):
            return type(
                "Result",
                (),
                {
                    "returncode": 1,
                    "stdout": "",
                    "stderr": "cannot connect to Nix daemon",
                },
            )()

        with (
            patch.object(collector.subprocess, "run", side_effect=run),
            patch.object(
                collector, "cache_status", side_effect=AssertionError("cache queried")
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "local store check failed"):
                collector.ensure_baseline(
                    OLD, "repo", "x86_64-linux", "nixosConfigurations.host"
                )

    def test_partial_head_journal_retains_successful_fragment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            journal = root / "journal.json"
            journal.write_text(
                json.dumps(
                    {
                        "conclusion": "failure",
                        "events": [
                            EVENT,
                            {"type": "BUILD", "success": True, "attr": "checks.lint"},
                            {
                                "type": "BUILD",
                                "success": False,
                                "attr": "nixosConfigurations.other",
                            },
                        ],
                    }
                )
            )
            with (
                patch.object(collector, "evaluate_base", return_value=OLD),
                patch.object(collector, "ensure_baseline"),
                patch.object(collector, "run_dix", return_value={"diffs": []}),
            ):
                collector.process_journal(
                    journal,
                    root / "base",
                    root / "fragments",
                    "x86_64-linux",
                    BASE,
                    HEAD,
                )
            record = json.loads(
                (
                    root
                    / "fragments"
                    / "x86_64-linux"
                    / "nixosConfigurations"
                    / "host"
                    / "record.json"
                ).read_text()
            )
            self.assertEqual((record["baseSha"], record["headSha"]), (BASE, HEAD))


if __name__ == "__main__":
    unittest.main()
