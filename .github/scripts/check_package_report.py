#!/usr/bin/env python3
"""Focused, portable checks for package report collection and rendering."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import flake_lock_package_report as renderer
import nix_fast_build_package_report as collector

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


def write_fragment(
    directory,
    lane,
    *,
    name="host",
    system="x86_64-linux",
    base=BASE,
    status="success",
    message="",
):
    path = Path(directory, lane, "record.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "name": name,
                "system": system,
                "baseSha": base,
                "headSha": HEAD,
                "packageReport": {
                    "status": status,
                    "message": message,
                    "diff": {"diffs": []} if status == "success" else None,
                },
            }
        )
    )
    return path


class PackageReportChecks(unittest.TestCase):
    def test_render_requires_every_ci_lane(self):
        systems = ("aarch64-linux", "x86_64-linux", "aarch64-darwin")
        with tempfile.TemporaryDirectory() as directory:
            for system in systems:
                path = write_fragment(directory, system, name=system, system=system)
            self.assertIn(
                "No package updates detected",
                renderer.render(directory, BASE, HEAD, systems),
            )
            path.unlink()
            with self.assertRaisesRegex(SystemExit, "lanes incomplete"):
                renderer.render(directory, BASE, HEAD, systems)

    def test_mixed_pairs_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            for index, base in enumerate((BASE, "c" * 40)):
                write_fragment(directory, str(index), base=base)
            with self.assertRaisesRegex(SystemExit, "mixed base/head pairs"):
                renderer.load_reports(directory)

    def test_fragment_text_cannot_create_markdown(self):
        with tempfile.TemporaryDirectory() as directory:
            write_fragment(
                directory,
                "host",
                name="host\n## forged heading",
                status="failed",
                message="<script>surprise</script> https://example.invalid ~~obsolete~~",
            )
            rendered = renderer.render(directory, BASE, HEAD)
            self.assertNotIn("\n## forged heading", rendered)
            self.assertNotIn("<script>", rendered)
            self.assertIn("https\\://example\\.invalid", rendered)
            self.assertIn("\\~\\~obsolete\\~\\~", rendered)

    def test_cachix_hit_realises_exact_path(self):
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            code = 1 if len(calls) == 1 else 0
            return subprocess.CompletedProcess(
                command, code, "", f"error: path '{OLD}' is not valid"
            )

        with (
            patch.object(collector.subprocess, "run", side_effect=run),
            patch.object(collector, "cache_status", return_value=200),
        ):
            collector.ensure_baseline(
                OLD, "repo", "x86_64-linux", "nixosConfigurations.host"
            )
        self.assertEqual(calls[1], ["nix-store", "--realise", OLD])
        self.assertFalse(any(command[1] == "build" for command in calls))

    def test_fallback_rejects_different_output(self):
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            if command[1] == "path-info":
                return subprocess.CompletedProcess(
                    command, 1, "", f"error: path '{OLD}' is not valid"
                )
            return subprocess.CompletedProcess(command, 0, NEW + "\n", "")

        with (
            patch.object(collector.subprocess, "run", side_effect=run),
            patch.object(collector, "cache_status", return_value=404),
        ):
            with self.assertRaisesRegex(ValueError, "baseline build differs"):
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

    def test_cache_service_error_is_fatal(self):
        def run(command, **kwargs):
            return subprocess.CompletedProcess(
                command, 1, "", f"error: path '{OLD}' is not valid"
            )

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
            return subprocess.CompletedProcess(
                command, 1, "", "cannot connect to Nix daemon"
            )

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
            fragments = root / "fragments"
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
                    fragments,
                    "x86_64-linux",
                    BASE,
                    HEAD,
                )
            path = fragments / "x86_64-linux/nixosConfigurations/host/record.json"
            self.assertEqual(list(fragments.rglob("record.json")), [path])
            record = json.loads(path.read_text())
            self.assertEqual(
                record["packageReport"],
                {"status": "success", "message": "", "diff": {"diffs": []}},
            )
            self.assertEqual((record["baseSha"], record["headSha"]), (BASE, HEAD))


if __name__ == "__main__":
    unittest.main()
