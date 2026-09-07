import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ci_cache_workflow as workflow


class WorkflowTests(unittest.TestCase):
    def test_missing_original_closure_fails_before_workload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            closure = root / "closure"
            closure.mkdir()
            links = root / "roots/x86_64-linux"
            links.mkdir(parents=True)
            (links / "host").symlink_to(closure)

            def path(value):
                return (
                    root / "roots"
                    if str(value) == "/nix/var/nix/gcroots/github-ci"
                    else Path(value)
                )

            with (
                patch.object(workflow, "Path", side_effect=path),
                patch.object(
                    workflow.subprocess,
                    "check_output",
                    return_value=f"{closure}\n{root}/missing\n",
                ),
                patch.object(workflow.subprocess, "run") as deep,
            ):
                with self.assertRaisesRegex(ValueError, "closure paths missing"):
                    workflow.verify(
                        {"roots": [str(closure)]}, "x86_64-linux", deep=False
                    )
                deep.assert_not_called()

    def test_coverage_is_exact_union_and_seed_excludes_outputs(self):
        nfb = {system: "/nix/store/nfb-" + system for system in workflow.SYSTEMS}
        proof = {
            "records": [
                {"system": system, "storePath": "/nix/store/output-" + system}
                for system in workflow.SYSTEMS
            ]
        }
        archive = {
            "inputs": {
                "nixpkgs": {
                    "path": "/nix/store/input",
                    "inputs": {"nested": {"path": "/nix/store/nested"}},
                }
            }
        }
        inputs = workflow.input_paths(archive)
        self.assertEqual(inputs["nixpkgs/nested"], "/nix/store/nested")
        total, parts = workflow.coverages(proof, inputs, nfb, {"definition": "sha"})
        self.assertEqual(
            set(total["roots"]),
            set(inputs.values())
            | set(nfb.values())
            | {r["storePath"] for r in proof["records"]},
        )
        self.assertEqual(
            parts["linux-seed-x86_64-linux"]["roots"],
            sorted([*inputs.values(), nfb["x86_64-linux"]]),
        )
        union = {"roots": [], "inputs": {}, "tools": {}}
        for part in parts.values():
            union["roots"].extend(part["roots"])
            for field in ("inputs", "tools"):
                union[field].update(part[field])
        self.assertEqual(
            workflow.generation.fingerprint(total),
            workflow.generation.fingerprint(union),
        )

    def test_receipt_rejects_fallback_and_verification_failure(self):
        component = "linux-full-x86_64-linux"
        pin = {"sha256": "a" * 64}
        selection = {
            "repo": "owner/repo",
            "generation": {"releaseId": 7, "components": {component: pin}},
        }
        manifest = {"coverage": {"roots": []}, "imageSha256": "b" * 64}
        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.dict(
                os.environ,
                {"GITHUB_REPOSITORY": "owner/repo", "CI_LINUX_CACHE_RESTORED": "false"},
            ),
            patch.object(workflow.generation, "read_selection", return_value=selection),
            patch.object(workflow.image, "load_manifest", return_value=(manifest, {})),
            patch.object(workflow, "verify") as verify,
        ):
            root = Path(tmp)
            with self.assertRaisesRegex(ValueError, "not restored"):
                workflow.receipt(root / "selection", component, root / "cold")
            verify.assert_not_called()
            mounted = root / "image.dmg"
            mounted.write_bytes(b"image")
            (root / "eager.json").write_text(
                json.dumps(
                    {
                        "releaseId": 7,
                        "manifestSha256": pin["sha256"],
                        "imageSha256": manifest["imageSha256"],
                    }
                )
            )
            with patch.dict(
                os.environ,
                {
                    "CI_LINUX_CACHE_RESTORED": "true",
                    "CI_LINUX_CACHE_IMAGE": str(mounted),
                },
            ):
                verify.side_effect = subprocess.CalledProcessError(
                    1, "nix store verify"
                )
                with self.assertRaises(subprocess.CalledProcessError):
                    workflow.receipt(root / "selection", component, root / "bad-nar")
                self.assertFalse((root / "bad-nar/receipt.json").exists())
                verify.side_effect = None
                workflow.receipt(root / "selection", component, root / "good")
                self.assertTrue(
                    json.loads((root / "good/receipt.json").read_text())["verified"]
                )

    def test_unchanged_coverage_still_supplies_current_housekeeping_source(self):
        revision = "f" * 40
        raw = json.dumps(
            {
                "revision": revision,
                "records": [
                    {"system": system, "storePath": "/nix/store/output-" + system}
                    for system in workflow.SYSTEMS
                ],
            }
        ).encode()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = root / "plan"

            def run(*argv):
                if argv == ("git", "rev-parse", "HEAD"):
                    return revision
                if argv[:3] == ("nix", "flake", "archive"):
                    return json.dumps(
                        {
                            "path": "/nix/store/checkout",
                            "inputs": {"nixpkgs": {"path": "/nix/store/input"}},
                        }
                    )
                return "/nix/store/tool" if argv[0] == "nix" else "definition"

            def resolve(*_args):
                return {
                    "generation": {
                        "source": {"revision": "a" * 40},
                        "coverage": json.loads(
                            (directory / "coverage.json").read_text()
                        ),
                    }
                }

            with (
                patch.dict(
                    os.environ,
                    {
                        "GITHUB_REPOSITORY": "owner/repo",
                        "GITHUB_OUTPUT": str(root / "output"),
                        "FORCE_REBUILD": "false",
                    },
                ),
                patch.object(workflow.subprocess, "check_output", return_value=raw),
                patch.object(workflow, "run", side_effect=run),
                patch.object(workflow.generation, "check_run"),
                patch.object(workflow.generation, "resolve", side_effect=resolve),
            ):
                workflow.plan(directory, "/nix/store/" + "a" * 32 + "-proof", 11)
            self.assertEqual((root / "output").read_text(), "refresh=false\n")
            source = json.loads((directory / "source.json").read_text())
            self.assertEqual(source["revision"], revision)
            self.assertEqual(source["runId"], 11)
            self.assertEqual(
                source["proof"]["sha256"], workflow.hashlib.sha256(raw).hexdigest()
            )

    def test_darwin_receipt_rejects_wrong_or_recovered_reader(self):
        component = "darwin-image-aarch64-darwin"
        selection = {
            "repo": "owner/repo",
            "generation": {
                "releaseId": 7,
                "components": {component: {"sha256": "a" * 64}},
            },
        }
        manifest = {"coverage": {"roots": []}, "imageSha256": "b" * 64}
        for case, message in (
            ("selection", "generation differs"),
            ("maintenance", "fell back"),
            ("records", "missing successful"),
            ("backing", "hot backing failed"),
        ):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                state = root / "darwin"
                (state / "selected").mkdir(parents=True)
                (state / "reader").mkdir()
                (state / "selection.json").write_text(
                    json.dumps({} if case == "selection" else selection)
                )
                (state / "mode.json").write_text(
                    json.dumps(
                        {"mode": "maintenance" if case == "maintenance" else "hot"}
                    )
                )
                if case != "records":
                    (state / "selected/records.json").write_text("[]")
                if case == "backing":
                    (state / "reader/backing-failure").touch()
                with (
                    patch.dict(
                        os.environ,
                        {"RUNNER_TEMP": tmp, "GITHUB_REPOSITORY": "owner/repo"},
                    ),
                    patch.object(
                        workflow.generation, "read_selection", return_value=selection
                    ),
                    patch.object(
                        workflow.image, "load_manifest", return_value=(manifest, {})
                    ),
                    patch.object(workflow, "verify") as verify,
                ):
                    with self.assertRaisesRegex(ValueError, message):
                        workflow.receipt(
                            root / "selection", component, root / "receipt"
                        )
                    verify.assert_not_called()
                    self.assertFalse((root / "receipt/receipt.json").exists())

    def test_nfb_remote_arguments_and_source_failure(self):
        script = Path(__file__).with_name("ci-nfb.sh").resolve()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nix = root / "nix"
            nix.write_text('#!/bin/sh\nprintf "%s\\n" "$STUB_NFB_PATH"\n')
            wrapper = root / "wrapper"
            wrapper.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['ARGV_LOG']).write_text(json.dumps(sys.argv[1:]))
args=sys.argv
result=Path(args[args.index('--result-file')+1])
result.write_text(json.dumps({'results':[
 {'type':'EVAL','success':True,'attr':'nixosConfigurations.host'},
 {'type':'BUILD','success':True,'attr':'nixosConfigurations.host','outputs':{'out':'/nix/store/output'}}]}))
sys.exit(int(os.environ.get('STUB_STATUS','0')))
""")
            nix.chmod(0o755)
            wrapper.chmod(0o755)
            env = {
                **os.environ,
                "PATH": str(root) + os.pathsep + os.environ["PATH"],
                "HOST_PYTHON": str(wrapper),
                "RUNNER_TEMP": tmp,
                "ARGV_LOG": str(root / "argv"),
                "STUB_NFB_PATH": tmp,
            }
            subprocess.run(
                ["bash", str(script), "linux-hosts", "x86_64-linux"],
                env=env,
                check=True,
                stdout=subprocess.DEVNULL,
            )
            args = json.loads((root / "argv").read_text())
            self.assertIn("ssh-ng://eu.nixbuild.net", args)
            self.assertNotIn("builders", args[args.index("--store") :])
            self.assertIn(".#ci.linux-hosts", args)
            env["STUB_STATUS"] = "1"
            failed = subprocess.run(
                ["bash", str(script), "linux-checks", "x86_64-linux"],
                env=env,
                stdout=subprocess.DEVNULL,
            )
            self.assertEqual(failed.returncode, 1)


if __name__ == "__main__":
    unittest.main()
