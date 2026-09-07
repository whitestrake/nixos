import copy
from pathlib import Path
import sys
import tempfile
import json
import io
import base64
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import ci_cache_generation as G
import ci_cache_image as I


def generation(release_id=7):
    return {
        "schema": G.SCHEMA,
        "releaseId": release_id,
        "source": {
            "revision": "a" * 40,
            "runId": 10,
            "proof": {
                "storePath": "/nix/store/" + "a" * 32 + "-ci-build-proof.json",
                "sha256": "b" * 64,
            },
        },
        "publisherRunId": 20,
        "coverage": {
            "roots": ["/nix/store/root"],
            "inputs": {"nixpkgs": "a"},
            "tools": {"nfb": "b"},
        },
        "components": {
            name: {
                "assetId": 30 + i,
                "name": name + ".json",
                "size": 100,
                "sha256": "c" * 64,
            }
            for i, name in enumerate(G.COMPONENTS)
        },
    }


class GenerationTest(unittest.TestCase):
    def test_asset_body_authenticates_draft_metadata_and_checks_digest(self):
        body = b"candidate"
        asset = {
            "id": 9,
            "name": "candidate.json",
            "size": len(body),
            "digest": "sha256:" + G.sha256(body),
            "browser_download_url": "https://attacker.example/unused",
        }
        pin = G.identity(asset)
        with (
            patch.object(G, "gh_download_whole", return_value=body) as authenticated,
            patch.object(G, "download_whole", return_value=body) as public,
        ):
            self.assertEqual(
                G.asset_body("owner/repo", {"draft": True, "assets": [asset]}, pin),
                body,
            )
            authenticated.assert_called_once_with("owner/repo", asset, 64 * 1024 * 1024)
            public.assert_not_called()

            self.assertEqual(
                G.asset_body("owner/repo", {"draft": False, "assets": [asset]}, pin),
                body,
            )
            public.assert_called_once_with(asset, 64 * 1024 * 1024)

            authenticated.return_value = b"candidaXe"
            with self.assertRaisesRegex(ValueError, "asset content digest mismatch"):
                G.asset_body("owner/repo", {"draft": True, "assets": [asset]}, pin)

    def test_seal_rejects_unrealised_coverage_and_component_conflicts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "image"
            source.write_bytes(b"abcdefgh")
            I.pack_image(source, root / "packed")
            draft = json.loads((root / "packed" / I.DRAFT_NAME).read_text())
            shard = draft["shards"][0]
            shard["assetId"] = 900
            payload = {
                "id": 900,
                "name": shard["name"],
                "size": shard["size"],
                "digest": "sha256:" + shard["sha256"],
            }
            for case in (
                "extra-root",
                "extra-input",
                "extra-tool",
                "component-root",
                "input-conflict",
                "tool-conflict",
            ):
                with self.subTest(case=case):
                    value = generation()
                    manifests = {}
                    assets = [payload]
                    for component, pin in value["components"].items():
                        manifest = copy.deepcopy(draft)
                        manifest.update(
                            releaseId=7,
                            component=component,
                            coverage=copy.deepcopy(value["coverage"]),
                        )
                        if component == "darwin-image-aarch64-darwin":
                            manifest["filesystemGate"] = {
                                key: draft["imageSha256"]
                                for key in (
                                    "imageSha256",
                                    "imageSha256Before",
                                    "imageSha256After",
                                )
                            }
                            manifest["filesystemGate"].update(
                                fsck="fsck_hfs -fn", fsckStatus=0
                            )
                        manifests[pin["assetId"]] = manifest
                        assets.append(
                            {
                                "id": pin["assetId"],
                                "name": pin["name"],
                                "size": pin["size"],
                                "digest": "sha256:" + pin["sha256"],
                            }
                        )
                    if case == "extra-root":
                        value["coverage"]["roots"].append("/nix/store/absent")
                    elif case in ("extra-input", "extra-tool"):
                        field = "inputs" if case == "extra-input" else "tools"
                        value["coverage"][field]["absent"] = "missing"
                    else:
                        coverage = manifests[
                            value["components"][G.COMPONENTS[-1]]["assetId"]
                        ]["coverage"]
                        if case == "component-root":
                            coverage["roots"].append("/nix/store/unclaimed")
                        else:
                            field = "inputs" if case == "input-conflict" else "tools"
                            coverage[field][next(iter(coverage[field]))] = "conflicting"
                    release = {"id": 7, "assets": assets}
                    with (
                        patch.object(G, "candidate", return_value=(release, value)),
                        patch.object(
                            G,
                            "asset_body",
                            side_effect=lambda _repo, _release, pin: json.dumps(
                                manifests[pin["assetId"]]
                            ).encode(),
                        ),
                        patch.object(G, "upload") as upload,
                        patch.object(G, "gh_api") as api,
                        patch.object(G, "resolve"),
                    ):
                        with self.assertRaises(ValueError):
                            G.seal("owner/repo", 7, root / "selection.json")
                        upload.assert_not_called()
                        api.assert_not_called()

    def test_oidc_context_rejects_spoofed_run_pr_and_foreign_endpoint(self):
        claims = {
            "iss": "https://token.actions.githubusercontent.com",
            "aud": "ci-cache-publisher",
            "repository": "owner/repo",
            "run_id": "20",
            "exp": 9999999999,
            "ref": "refs/heads/master",
            "workflow_ref": "owner/repo/" + G.PUBLISHER + "@refs/heads/master",
        }
        environment = {
            "ACTIONS_ID_TOKEN_REQUEST_URL": "https://run-actions-1-azure-eastus.actions.githubusercontent.com/idtoken?api-version=2.0",
            "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "test-token",
        }

        def response():
            encoded = (
                base64.urlsafe_b64encode(json.dumps(claims).encode())
                .decode()
                .rstrip("=")
            )
            return io.BytesIO(
                json.dumps({"value": "header." + encoded + ".signature"}).encode()
            )

        with (
            patch.dict(G.os.environ, environment),
            patch.object(G.urllib.request, "build_opener") as opener,
        ):
            opener.return_value.open.side_effect = lambda *_args, **_kwargs: response()
            self.assertEqual(G.publisher_claims("owner/repo", 20, True)["run_id"], "20")
            with self.assertRaises(ValueError):
                G.publisher_claims("owner/repo", 21, True)
            claims.update(
                ref="refs/heads/feature",
                workflow_ref="owner/repo/" + G.PUBLISHER + "@refs/heads/feature",
            )
            with self.assertRaises(ValueError):
                G.publisher_claims("owner/repo", 20, True)
            G.publisher_claims("owner/repo", 20, False)
            with patch.dict(
                G.os.environ,
                {"ACTIONS_ID_TOKEN_REQUEST_URL": "https://attacker.example/idtoken"},
            ):
                with self.assertRaises(ValueError):
                    G.publisher_claims("owner/repo", 20, False)

    def test_complete_direct_upload_seals_one_release_with_distinct_component_assets(
        self,
    ):
        value = generation()
        release = {
            "id": 7,
            "tag_name": "ci-cache-v1-20001",
            "target_commitish": value["source"]["revision"],
            "author": {"login": "github-actions[bot]"},
            "draft": True,
            "assets": [],
        }
        bodies = {}
        mutations = []

        def api(_repo, _endpoint, method="GET", payload=None):
            if method == "PATCH":
                mutations.append(payload)
                release.update(payload)
            return copy.deepcopy(release)

        def upload(_repo, _tag, path):
            asset_id = len(bodies) + 1
            body = Path(path).read_bytes()
            bodies[asset_id] = body
            release["assets"].append(
                {
                    "id": asset_id,
                    "name": Path(path).name,
                    "size": len(body),
                    "digest": "sha256:" + G.sha256(body),
                    "browser_download_url": "unused",
                }
            )

        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(G, "gh_api", side_effect=api),
            patch.object(G, "gh_upload", side_effect=upload),
            patch.object(
                G,
                "asset_body",
                side_effect=lambda _repo, _r, pin, *_args: bodies[pin["assetId"]],
            ),
            patch.object(G, "publisher_context", return_value=20),
            patch.object(G, "trusted_generation"),
            patch.object(G, "verify_proof"),
        ):
            root = Path(directory)
            result = G.begin("owner/repo", value["source"], value["coverage"])
            self.assertEqual(result["releaseId"], 7)
            source = root / "image"
            source.write_bytes(b"abcdefgh")
            for component in G.COMPONENTS:
                packed = root / component
                I.pack_image(source, packed)
                draft_path = packed / I.DRAFT_NAME
                draft = json.loads(draft_path.read_text())
                draft["coverage"] = value["coverage"]
                if component == "darwin-image-aarch64-darwin":
                    digest = draft["imageSha256"]
                    draft["filesystemGate"] = {
                        key: digest
                        for key in (
                            "imageSha256",
                            "imageSha256Before",
                            "imageSha256After",
                        )
                    }
                    draft["filesystemGate"].update(fsck="fsck_hfs -fn", fsckStatus=0)
                    hot = packed / "hot.bin"
                    hot.write_bytes(b"hot-pack")
                    draft["hotPack"] = {
                        "name": hot.name,
                        "size": 8,
                        "sha256": G.file_sha256(hot),
                    }
                draft_path.write_text(json.dumps(draft))
                G.upload_component("owner/repo", 7, component, packed)
                with self.assertRaises(ValueError):
                    G.upload_component("owner/repo", 7, component, packed)
            selection = G.seal("owner/repo", 7, root / "selection.json")
            self.assertEqual(
                set(selection["generation"]["components"]), set(G.COMPONENTS)
            )
            self.assertEqual(mutations, [{"draft": False, "make_latest": "false"}])
            self.assertEqual(
                len({a["name"] for a in release["assets"]}), len(release["assets"])
            )

    def test_seal_incomplete_generation_never_publishes(self):
        with (
            patch.object(
                G, "candidate", return_value=({"id": 7, "assets": []}, generation())
            ),
            patch.object(G, "gh_api") as api,
        ):
            with self.assertRaises(ValueError):
                G.seal("owner/repo", 7, "unused")
            api.assert_not_called()

    def test_receipt_from_another_run_is_rejected_before_download(self):
        meta = {"id": 99, "expired": False, "workflow_run": {"id": 999}}
        with (
            patch.object(G, "gh_api", return_value=meta),
            patch.object(G.subprocess, "run") as run,
        ):
            with self.assertRaises(ValueError):
                G.read_receipt("owner/repo", 99, generation(), G.COMPONENTS[0])
            run.assert_not_called()

    def test_promotion_time_is_after_confirmed_latest_and_failure_cannot_prune(self):
        value = generation()
        pin = {"assetId": 99, "name": G.MANIFEST, "size": 1, "sha256": "d" * 64}
        release = {"id": 7, "assets": [], "tag_name": "ci-cache-v1-7"}
        mutations = []
        latest_reads = 0

        def api(_repo, endpoint, method="GET", payload=None):
            nonlocal latest_reads
            if method == "PATCH":
                mutations.append("promoted")
                return release
            if endpoint == "releases/latest":
                latest_reads += 1
                return {"id": 1, "tag_name": "legacy"} if not mutations else release
            return release

        def upload(_repo, _release, path):
            if path.name == "promotion-intent.json":
                self.assertEqual(mutations, [])
                return pin
            self.assertEqual(mutations, ["promoted"])
            record = json.loads(path.read_text())
            self.assertEqual(record["promotedAt"], 200000)
            self.assertEqual(record["publisherRunId"], 20)
            raise OSError("interrupted receipt upload")

        receipts = {name: 100 + i for i, name in enumerate(G.COMPONENTS)}
        with (
            patch.object(
                G, "read_selection", return_value={"generation": value, "manifest": pin}
            ),
            patch.object(G, "load_generation", return_value=(value, pin)),
            patch.object(G, "publisher_context", return_value=20),
            patch.object(G, "verify_proof"),
            patch.object(G, "gh_api", side_effect=api),
            patch.object(
                G,
                "read_receipt",
                return_value={
                    "imageSha256": "e" * 64,
                    "filesystemVerified": True,
                    "hotPackSha256": "f" * 64,
                },
            ),
            patch.object(
                G,
                "asset_body",
                return_value=json.dumps(
                    {"imageSha256": "e" * 64, "hotPack": {"sha256": "f" * 64}}
                ).encode(),
            ),
            patch.object(G.time, "time", return_value=200000),
            patch.object(
                G,
                "promotion_intent",
                return_value=(
                    {
                        "releaseId": 7,
                        "previousId": None,
                        "publisherRunId": 20,
                        "receipts": receipts,
                    },
                    pin,
                ),
            ),
            patch.object(G, "upload", side_effect=upload),
        ):
            with self.assertRaises(OSError):
                G.promote("owner/repo", "unused", receipts)
        self.assertEqual(G.retirement_plan([release], [], 999999), [])

    def test_interrupted_promotion_reconciles_with_later_grace(self):
        release = {"id": 7, "assets": []}
        intent = {"releaseId": 7, "previousId": 6, "publisherRunId": 20, "receipts": {}}
        pin = {"sha256": "f" * 64}
        with (
            patch.object(G, "promotion_intent", return_value=(intent, pin)),
            patch.object(G, "latest_release", return_value=release),
            patch.object(G.time, "time", return_value=300000),
            patch.object(G, "upload") as upload,
        ):
            record = G.finish_promotion("owner/repo", release, recovery_run=21)
            self.assertEqual(record["promotedAt"], 300000)
            self.assertEqual(record["previousId"], 6)
            self.assertEqual(record["recoveredByRunId"], 21)
            upload.assert_called_once()

    def test_housekeeping_uses_current_source_and_reconciles_before_grace(self):
        old = generation()
        source = copy.deepcopy(old["source"])
        source.update(revision="f" * 40, runId=11)
        releases = [
            {"id": i, "tag_name": f"ci-cache-v1-{i}", "assets": [], "draft": False}
            for i in (7, 6, 5)
        ]
        latest = releases[0]
        bodies = {}

        def add(release, name, value):
            body = json.dumps(value).encode()
            asset_id = len(bodies) + 100
            bodies[asset_id] = body
            release["assets"].append(
                {
                    "id": asset_id,
                    "name": name,
                    "size": len(body),
                    "digest": "sha256:" + G.sha256(body),
                }
            )
            return G.identity(release["assets"][-1])

        for index, release in enumerate(releases):
            intent = {
                "releaseId": release["id"],
                "previousId": releases[index + 1]["id"] if index < 2 else None,
                "publisherRunId": 20,
            }
            pin = add(release, "promotion-intent.json", intent)
            if index:
                add(
                    release,
                    "promotion.json",
                    {
                        **intent,
                        "intentSha256": pin["sha256"],
                        "promotedAt": 100000 - index,
                    },
                )
        mutations = []

        def api(_repo, endpoint, method="GET", payload=None):
            if method != "GET":
                mutations.append(endpoint)
                return None
            if endpoint == "releases/latest":
                return latest
            if endpoint.startswith("releases?"):
                return releases
            if endpoint.startswith("releases/"):
                return next(
                    r for r in releases if r["id"] == int(endpoint.split("/")[-1])
                )
            if endpoint.startswith("git/ref/tags/"):
                return {
                    "ref": "refs/tags/" + endpoint.split("/")[-1],
                    "object": {"type": "commit", "sha": old["source"]["revision"]},
                }
            raise AssertionError(endpoint)

        def publisher(_repo, revision, production):
            self.assertEqual(revision, source["revision"])
            self.assertTrue(production)
            return 21

        def upload(_repo, release, path):
            mutations.append(path.name)
            return add(release, path.name, json.loads(path.read_text()))

        with (
            patch.object(G, "gh_api", side_effect=api),
            patch.object(G, "publisher_context", side_effect=publisher),
            patch.object(G, "check_run") as check,
            patch.object(G, "verify_proof") as proof,
            patch.object(
                G,
                "load_generation",
                side_effect=lambda _repo, rid, **_kwargs: (
                    {**old, "releaseId": rid},
                    {},
                ),
            ),
            patch.object(
                G,
                "asset_body",
                side_effect=lambda _repo, _release, pin, *_args: bodies[pin["assetId"]],
            ),
            patch.object(G, "upload", side_effect=upload),
            patch.object(G.time, "time", return_value=300000) as now,
        ):
            self.assertEqual(G.prune("owner/repo", source)["releaseIds"], [])
            self.assertEqual(mutations, [])
            self.assertEqual(G.prune("owner/repo", source, True)["releaseIds"], [])
            record = json.loads(bodies[latest["assets"][-1]["id"]])
            self.assertEqual(record["promotedAt"], 300000)
            self.assertEqual(record["recoveredByRunId"], 21)
            self.assertEqual(mutations, ["promotion.json"])
            check.assert_called_with(
                "owner/repo",
                11,
                source["revision"],
                G.SOURCE_WORKFLOW,
                production=True,
                successful=True,
            )
            proof.assert_called_with(source, production=True)
            now.return_value += G.GRACE
            self.assertEqual(G.prune("owner/repo", source, True)["releaseIds"], [5])
            self.assertEqual(
                mutations[-2:], ["releases/5", "git/refs/tags/ci-cache-v1-5"]
            )
            for guard in (check, proof):
                guard.side_effect = ValueError("untrusted or failed source")
                before = mutations[:]
                with self.assertRaises(ValueError):
                    G.prune("owner/repo", source, True)
                self.assertEqual(mutations, before)
                guard.side_effect = None

    def test_housekeeping_rejects_unsafe_current_publisher_and_failed_source(self):
        source = generation()["source"]
        publisher = {
            "id": 21,
            "head_sha": source["revision"],
            "head_branch": "master",
            "event": "workflow_run",
            "path": G.PUBLISHER,
            "head_repository": {"full_name": "owner/repo"},
        }
        for case in ("oidc", "foreign", "feature", "stale", "failed-source", "proof"):
            with self.subTest(case=case):
                run = copy.deepcopy(publisher)
                if case == "foreign":
                    run["head_repository"]["full_name"] = "foreign/repo"
                if case == "feature":
                    run["head_branch"] = "feature"

                def api(_repo, endpoint):
                    if endpoint == "actions/runs/21":
                        return run
                    if endpoint == "commits/master":
                        return {
                            "sha": "f" * 40 if case == "stale" else source["revision"]
                        }
                    if endpoint == "actions/runs/10":
                        return {
                            **publisher,
                            "id": 10,
                            "path": G.SOURCE_WORKFLOW,
                            "status": "completed",
                            "conclusion": "failure"
                            if case == "failed-source"
                            else "success",
                        }
                    raise AssertionError(
                        "must reject before Release access: " + endpoint
                    )

                with (
                    patch.dict(
                        G.os.environ,
                        {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_RUN_ID": "21"},
                    ),
                    patch.object(G, "gh_api", side_effect=api),
                    patch.object(
                        G,
                        "publisher_claims",
                        side_effect=ValueError("OIDC rejected")
                        if case == "oidc"
                        else None,
                    ),
                    patch.object(
                        G,
                        "verify_proof",
                        side_effect=ValueError("proof rejected")
                        if case == "proof"
                        else None,
                    ),
                    patch.object(G, "upload") as upload,
                ):
                    with self.assertRaises(ValueError):
                        G.prune("owner/repo", source, True)
                    upload.assert_not_called()

    def test_no_latest_is_cold_but_other_api_failures_are_errors(self):
        for status in (404, 500):
            error = G.subprocess.CalledProcessError(
                1, "gh", stderr=f"HTTP {status}".encode()
            )
            with patch.object(G, "gh_api", side_effect=error):
                if status == 404:
                    self.assertIsNone(G.latest_release("owner/repo"))
                else:
                    with self.assertRaises(G.subprocess.CalledProcessError):
                        G.latest_release("owner/repo")

    def test_incomplete_and_bad_identity_rejected(self):
        valid = generation()
        G.validate_generation(valid)
        for mutation in (
            lambda g: g["components"].pop(G.COMPONENTS[0]),
            lambda g: g["components"][G.COMPONENTS[0]].update(sha256="bad"),
            lambda g: g["components"][G.COMPONENTS[0]].update(name="../evil"),
            lambda g: g.update(releaseId=True),
        ):
            value = copy.deepcopy(valid)
            mutation(value)
            with self.assertRaises(ValueError):
                G.validate_generation(value)

    def test_selection_resolves_once_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "selection.json"
            with patch.object(
                G,
                "load_generation",
                return_value=(
                    generation(),
                    {
                        "assetId": 99,
                        "name": G.MANIFEST,
                        "size": 100,
                        "sha256": "d" * 64,
                    },
                ),
            ) as load:
                G.resolve("owner/repo", output)
                with self.assertRaises(FileExistsError):
                    G.resolve("owner/repo", output)
                self.assertEqual(load.call_count, 1)
                self.assertEqual(
                    G.read_selection(output, "owner/repo")["generation"]["releaseId"], 7
                )

    def test_retirement_grace_starts_at_successor_promotion(self):
        releases = [
            {"id": i, "tag_name": f"ci-cache-v1-{i}", "draft": False}
            for i in range(1, 5)
        ]
        chain = [
            {"releaseId": 4, "previousId": 3, "promotedAt": 200000},
            {"releaseId": 3, "previousId": 2, "promotedAt": 100000},
            {"releaseId": 2, "previousId": 1, "promotedAt": 1},
        ]
        self.assertEqual(G.retirement_plan(releases, chain, 200010), [1])
        self.assertEqual(G.retirement_plan(releases, chain, 286400), [1, 2])
        releases[0]["tag_name"] = "unowned"
        self.assertEqual(G.retirement_plan(releases, chain, 286400), [2])

    def test_authenticated_run_rejects_pr_and_wrong_workflow(self):
        run = {
            "id": 20,
            "head_sha": "a" * 40,
            "head_branch": "master",
            "event": "workflow_dispatch",
            "path": G.PUBLISHER,
            "head_repository": {"full_name": "owner/repo"},
        }
        with patch.object(G, "gh_api", return_value=run):
            G.check_run("owner/repo", 20, "a" * 40, G.PUBLISHER, production=True)
            run["event"] = "pull_request"
            with self.assertRaises(ValueError):
                G.check_run("owner/repo", 20, "a" * 40, G.PUBLISHER, production=True)


if __name__ == "__main__":
    unittest.main()
