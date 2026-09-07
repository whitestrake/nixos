import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import ci_darwin as darwin


class RecoveryTests(unittest.TestCase):
    def test_setup_recovery_requires_fault_and_consumes_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            darwin.write_json(root / "mode.json", {"mode": "hot", "repo": "owner/repo"})
            events = []

            def mount(state, mode, repo):
                events.append((mode, repo))
                darwin.write_json(state / "mode.json", {"mode": mode, "repo": repo})

            with (
                patch.object(darwin, "helper_fault", return_value=None) as fault,
                patch.object(
                    darwin, "cleanup", side_effect=lambda _: events.append("cleanup")
                ),
                patch.object(darwin, "mount", side_effect=mount),
                patch.object(darwin, "recovery_ready") as ready,
            ):
                self.assertEqual(darwin.recover_setup(root), {"recovered": False})
                self.assertEqual(events, [])
                fault.return_value = "backing-failure"
                self.assertTrue(darwin.recover_setup(root)["recovered"])
                self.assertEqual(events, ["cleanup", ("maintenance", "owner/repo")])
                ready.assert_not_called()
                self.assertFalse(darwin.recover_setup(root)["recovered"])
                self.assertEqual(len(events), 2)
            darwin.write_json(root / "mode.json", {"mode": "hot", "repo": "owner/repo"})
            with (
                patch.object(darwin, "helper_fault", return_value="backing-failure"),
                patch.object(darwin, "cleanup", side_effect=RuntimeError("busy store")),
                patch.object(darwin, "mount") as mounted,
            ):
                with self.assertRaisesRegex(RuntimeError, "busy store"):
                    darwin.recover_setup(root)
                mounted.assert_not_called()

    def test_recovery_selection_and_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            events = []

            def attempt(directory, number):
                events.append(f"run{number}")
                (directory / "results.json").write_text(str(number))
                (directory / "proof").write_text(str(number))
                return (1, "backing-failure") if number == 1 else (0, None)

            def recover():
                events.append("detach-mount")
                self.assertFalse((root / "attempt-1").exists())

            self.assertEqual(darwin.transaction(root, attempt, recover), 0)
            self.assertEqual(events, ["run1", "detach-mount", "run2"])
            self.assertEqual((root / "selected/results.json").read_text(), "2")

    def test_terminal_failure_and_bounded_retry(self):
        for fault, count in [(None, 1), ("helper-exited", 2)]:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as tmp:
                attempts = []

                def attempt(directory, number):
                    attempts.append(number)
                    return 9, fault

                self.assertEqual(
                    darwin.transaction(Path(tmp), attempt, lambda: None), 9
                )
                self.assertEqual(len(attempts), count)
                self.assertFalse((Path(tmp) / "selected").exists())

    def test_real_helper_loss_stops_command_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            helper = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(.2)"],
                start_new_session=True,
            )
            status, reason = darwin.supervise(
                [sys.executable, "-c", "import time; time.sleep(30)"],
                root,
                helper.pid,
            )
            helper.wait()
            self.assertNotEqual(status, 0)
            self.assertEqual(reason, "helper-exited")

    def test_stopped_helper_and_explicit_marker(self):
        import signal

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            helper = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(30)"],
                start_new_session=True,
            )
            try:
                os.kill(helper.pid, signal.SIGSTOP)
                self.assertEqual(
                    darwin.helper_fault(helper.pid, root / "fault"), "helper-stopped"
                )
                (root / "fault").write_text("cache-backing-failure\n")
                self.assertEqual(
                    darwin.helper_fault(helper.pid, root / "fault"), "backing-failure"
                )
            finally:
                os.kill(helper.pid, signal.SIGKILL)
                helper.wait()

    def test_helper_ready_timeout_is_explicit(self):
        from unittest.mock import Mock, patch

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            process = Mock(pid=123)
            with (
                patch.object(darwin.subprocess, "Popen", return_value=process),
                patch.object(darwin, "helper_fault", return_value=None),
                patch.object(darwin, "stop_group") as stopped,
                patch.object(darwin.time, "monotonic", side_effect=[0, 601]),
            ):
                with self.assertRaisesRegex(RuntimeError, "helper-start-timeout"):
                    darwin.start_helper(root, [])
            stopped.assert_called_once_with(123, process)
            process.wait.assert_called_once()
            self.assertEqual(
                (root / "startup-failure").read_text(), "helper-start-timeout"
            )

    def test_native_command_timeout_reaps_owned_process(self):
        with tempfile.TemporaryDirectory() as tmp:
            pid_file = Path(tmp) / "pid"
            with self.assertRaises(subprocess.TimeoutExpired):
                darwin.command(
                    sys.executable,
                    "-c",
                    f"import os,time; open({str(pid_file)!r}, 'w').write(str(os.getpid())); time.sleep(30)",
                    timeout=0.2,
                )
            result = subprocess.run(
                ["ps", "-o", "stat=", "-p", pid_file.read_text()],
                capture_output=True,
                text=True,
            )
            self.assertFalse(result.stdout.strip())

    def test_cleanup_failure_prevents_second_attempt(self):
        with tempfile.TemporaryDirectory() as tmp:
            attempts = []

            def attempt(directory, number):
                attempts.append(number)
                return 1, "backing-failure"

            def recover():
                raise RuntimeError("detach failed")

            with self.assertRaisesRegex(RuntimeError, "detach failed"):
                darwin.transaction(Path(tmp), attempt, recover)
            self.assertEqual(attempts, [1])

    def test_ordinary_failure_is_not_cache_fault(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(
                darwin.supervise(
                    [sys.executable, "-c", "raise SystemExit(7)"], Path(tmp)
                ),
                (7, None),
            )


class PublicationTests(unittest.TestCase):
    def test_selected_failure_checks_and_owned_descendants(self):
        import nix_fast_build as nfb
        from unittest.mock import Mock

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            child = root / "child.pid"
            script = root / "nfb.py"
            script.write_text(
                "import json, subprocess, sys\n"
                "p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], stdout=subprocess.DEVNULL)\n"
                f"open({str(child)!r}, 'w').write(str(p.pid))\n"
                "print(json.dumps({'type':'EVAL', 'attr':'ci.test', 'success': False}))\n"
                "raise SystemExit(7)\n"
            )
            journal = root / "checks.json"
            publisher = Mock()
            self.assertEqual(
                nfb.run([sys.executable, str(script)], publisher, None, str(journal)),
                (7, False),
            )
            publisher.handle.assert_not_called()
            publisher.finalize.assert_not_called()
            nfb.replay_checks(publisher, journal)
            publisher.handle.assert_called_once()
            publisher.finalize.assert_called_once_with("failure")
            status = subprocess.run(
                ["ps", "-o", "stat=", "-p", child.read_text()],
                capture_output=True,
                text=True,
            ).stdout.strip()
            self.assertTrue(not status or status.startswith("Z"), status)

    def test_only_discarded_fault_checks_are_suppressed(self):
        for fault in (None, "backing-failure"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as tmp:
                published = []

                def attempt(directory, number):
                    (directory / "checks.json").write_text(str(number))
                    return (7, fault) if number == 1 else (0, None)

                darwin.transaction(
                    Path(tmp),
                    attempt,
                    lambda: None,
                    lambda directory: published.append(
                        (directory / "checks.json").read_text()
                    ),
                )
                self.assertEqual(published, ["2"] if fault else ["1"])


class ArchiveTests(unittest.TestCase):
    def test_archive_boundary_and_structure(self):
        import io
        import plistlib
        import tarfile
        from unittest.mock import patch

        for invalid in (None, "../escape", "/absolute", "sibling/file", "link"):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                archive = root / "bundle.tar"
                with tarfile.open(archive, "w") as stream:
                    entries = {
                        "nix-root.sparsebundle/Info.plist": plistlib.dumps(
                            {
                                "diskimage-bundle-type": "com.apple.diskimage.sparsebundle",
                                "size": 1024,
                            }
                        ),
                        "nix-root.sparsebundle/token": b"",
                        "nix-root.sparsebundle/bands/0": b"band",
                    }
                    if invalid:
                        entries[
                            invalid
                            if invalid != "link"
                            else "nix-root.sparsebundle/link"
                        ] = b"bad"
                    for name, data in entries.items():
                        member = tarfile.TarInfo(name)
                        member.size = len(data)
                        if invalid == "link" and name.endswith("/link"):
                            member.type = tarfile.SYMTYPE
                            member.linkname = "/tmp/escape"
                        stream.addfile(member, io.BytesIO(data))
                # Only substitute decompression; the real streaming tar parser and writes run.
                real_popen = subprocess.Popen
                with patch.object(
                    darwin.subprocess,
                    "Popen",
                    side_effect=lambda *_args, **kwargs: real_popen(
                        ["cat", str(archive)], **kwargs
                    ),
                ):
                    if invalid:
                        with self.assertRaises(ValueError):
                            darwin.safe_extract(archive, root / "extracted")
                    else:
                        bundle = darwin.safe_extract(archive, root / "extracted")
                        self.assertEqual((bundle / "bands/0").read_bytes(), b"band")


class ProducerTests(unittest.TestCase):
    def test_hot_validation_uses_exact_image_and_fresh_blocks(self):
        import json

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "image"
            source.write_bytes(b"a" * 65536)
            packed = root / "packed"
            darwin.image.pack_image(source, packed)
            manifest_path = packed / "draft-manifest.json"
            manifest = json.loads(manifest_path.read_text())
            profile = root / "profile.jsonl"
            profile.write_text(
                json.dumps(
                    {
                        "kind": 1,
                        "status": 206,
                        "valid": 1,
                        "assetId": 1,
                        "start": 0,
                        "end": 65535,
                    }
                )
                + "\n"
            )
            hot = root / "hot.bin"
            darwin.image.pack_hot(source, manifest_path, profile, hot)
            darwin.validate_hot(source, manifest, hot, root / "fresh")
            self.assertEqual(len(list((root / "fresh/blocks").glob("*.block"))), 1)
            source.write_bytes(b"b" * 65536)
            with self.assertRaisesRegex(ValueError, "local image identity mismatch"):
                darwin.validate_hot(source, manifest, hot, root / "wrong")
            source.write_bytes(b"a" * 65536)
            data = bytearray(hot.read_bytes())
            data[-1] ^= 1
            hot.write_bytes(data)
            with self.assertRaisesRegex(ValueError, "hot-pack block digest mismatch"):
                darwin.validate_hot(source, manifest, hot, root / "corrupt")


if __name__ == "__main__":
    unittest.main()
