#!/usr/bin/env python3
"""Focused checks for the nix-fast-build wrapper's download watchdog."""

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


if __name__ == "__main__":
    unittest.main()
