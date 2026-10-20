#!/usr/bin/env python3
"""Focused checks for the nix-fast-build wrapper and its records filter."""

import json
from pathlib import Path
import subprocess
import threading
import unittest
from unittest import mock

import nix_fast_build


class DownloadWatchCheck(unittest.TestCase):
    def test_elapsed_seconds_reads_ps_etime(self):
        self.assertEqual(nix_fast_build.elapsed_seconds("00:42"), 42)
        self.assertEqual(nix_fast_build.elapsed_seconds("05:01"), 301)
        self.assertEqual(nix_fast_build.elapsed_seconds("01:00:00"), 3600)
        self.assertEqual(nix_fast_build.elapsed_seconds("2-00:00:05"), 172805)

    def test_long_downloads_names_lingering_fetches_only(self):
        listing = (
            "  101   12:30 /nix/store/abc-curl-8.22.0-bin/bin/curl --location"
            " https://user:secret@example.org/a.tar.gz\n"
            "  102   00:20 /nix/store/abc-curl-8.22.0-bin/bin/curl https://example.org/fresh\n"
            "  103   40:00 /nix/store/def-nix-2.34.7/bin/nix build\n"
            "  104 1-00:00:00 git fetch https://example.org/repo\n"
        )
        result = subprocess.CompletedProcess([], 0, stdout=listing)
        with mock.patch.object(nix_fast_build.subprocess, "run", return_value=result):
            found = list(nix_fast_build.long_downloads(300))
        self.assertEqual([pid for pid, _, _ in found], [101, 104])
        self.assertIn("://***@example.org", found[0][2])
        self.assertNotIn("secret", found[0][2])

    def test_watch_reports_each_download_once_per_window(self):
        stop = threading.Event()
        calls = iter([True, True, False])
        stop.wait = lambda _interval: not next(calls)
        found = [(101, "06:00", "curl https://example.org/a")]
        lsof = subprocess.CompletedProcess(
            [],
            0,
            stdout="COMMAND PID\ncurl 101 TCP 10.0.0.1:5->1.2.3.4:443 (ESTABLISHED)\n",
        )
        with (
            mock.patch.object(nix_fast_build, "long_downloads", return_value=found),
            mock.patch.object(nix_fast_build.subprocess, "run", return_value=lsof),
            mock.patch("sys.stderr") as stderr,
        ):
            nix_fast_build.watch_downloads(stop, 300, 30)
        written = "".join(call.args[0] for call in stderr.write.call_args_list)
        self.assertEqual(written.count("Download running for 06:00 (pid 101)"), 1)
        self.assertIn("CI_DOWNLOAD_SOCKET pid=101", written)


RECORDS = Path(__file__).with_name("nix-fast-build-records.jq")


def records(results):
    return subprocess.run(
        ["jq", "-ce", "-f", RECORDS],
        input=json.dumps({"results": results}),
        capture_output=True,
        text=True,
    )


def evaluated(attr, **extra):
    return {"type": "EVAL", "success": True, "attr": attr, **extra}


def built(attr, path):
    return {"type": "BUILD", "success": True, "attr": attr, "outputs": {"out": path}}


class RecordsCheck(unittest.TestCase):
    # This filter decides which hosts reach the build proof and deploy matrix.
    def test_records_pair_each_evaluated_configuration_with_its_output(self):
        result = records(
            [
                evaluated("nixosConfigurations.pascal"),
                built("nixosConfigurations.pascal", "/nix/store/p"),
                evaluated(
                    "darwinConfigurations.andred",
                    cacheStatus="cached",
                    outputs={"out": "/nix/store/a"},
                ),
                evaluated("checks.treefmt"),
                built("checks.treefmt", "/nix/store/t"),
                {
                    "type": "BUILD",
                    "success": False,
                    "attr": "nixosConfigurations.pascal",
                },
            ]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            [
                {
                    "attr": "darwinConfigurations.andred",
                    "kind": "darwinConfiguration",
                    "name": "andred",
                    "storePath": "/nix/store/a",
                },
                {
                    "attr": "nixosConfigurations.pascal",
                    "kind": "nixosConfiguration",
                    "name": "pascal",
                    "storePath": "/nix/store/p",
                },
            ],
        )

    def test_records_refuse_incomplete_or_ambiguous_results(self):
        for name, results, message in (
            (
                "unbuilt host",
                [
                    evaluated("nixosConfigurations.a"),
                    evaluated("nixosConfigurations.b"),
                    built("nixosConfigurations.a", "/nix/store/a"),
                ],
                "do not match",
            ),
            (
                "duplicate build",
                [
                    evaluated("nixosConfigurations.a"),
                    built("nixosConfigurations.a", "/nix/store/a"),
                    built("nixosConfigurations.a", "/nix/store/b"),
                ],
                "duplicate successful BUILD",
            ),
            (
                "missing output",
                [
                    evaluated("nixosConfigurations.a"),
                    {
                        "type": "BUILD",
                        "success": True,
                        "attr": "nixosConfigurations.a",
                        "outputs": {},
                    },
                ],
                "missing outputs.out",
            ),
            ("nothing evaluated", [evaluated("checks.treefmt")], "no successful EVAL"),
            (
                "unexpected attribute",
                [evaluated("packages.x86_64-linux.foo")],
                "unexpected nix-fast-build attribute",
            ),
        ):
            with self.subTest(name):
                result = records(results)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)


if __name__ == "__main__":
    unittest.main()
