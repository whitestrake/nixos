#!/usr/bin/env python3
"""Small portable checks for cache data and retention boundaries."""

import copy
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile

import ci_cache_generation as generation
import ci_cache_image as image
import ci_darwin as darwin


DATA = b"abcdefghijkl"


def packed(root):
    source = root / "image"
    source.write_bytes(DATA)
    output = root / "packed"
    image.pack_image(source, output, shard_size=8, block_size=4)
    manifest = json.loads((output / image.DRAFT_NAME).read_text())
    manifest["releaseId"] = 7
    for asset_id, shard in enumerate(manifest["shards"], 10):
        shard["assetId"] = asset_id
    image.validate_manifest(manifest)
    return source, manifest


def complete_generation():
    return {
        "schema": generation.SCHEMA,
        "releaseId": 7,
        "source": {
            "revision": "a" * 40,
            "runId": 8,
            "proof": {
                "storePath": "/nix/store/" + "0" * 32 + "-ci-build-proof.json",
                "sha256": "b" * 64,
            },
        },
        "publisherRunId": 9,
        "coverage": {
            "roots": ["/nix/store/root"],
            "inputs": {"nixpkgs": "/nix/store/input"},
            "tools": {"nix-fast-build": "/nix/store/tool"},
        },
        "components": {
            name: {
                "assetId": 20 + index,
                "name": name + ".json",
                "size": 100,
                "sha256": format(20 + index, "064x"),
            }
            for index, name in enumerate(generation.COMPONENTS)
        },
    }


class CacheCheck(unittest.TestCase):
    def test_range_download_retries_truncation_once_and_rejects_bad_headers(self):
        url = "https://example.invalid/shard"
        asset = {"size": len(DATA), "browser_download_url": url}
        for to_file in (False, True):
            for bodies, content_range, succeeds, calls in (
                ([DATA[:4], DATA], "bytes 0-11/12", True, 2),
                ([DATA[:4], DATA[:4]], "bytes 0-11/12", False, 2),
                ([DATA[:4], DATA], "bytes 1-12/12", False, 1),
                ([DATA + b"x", DATA], "bytes 0-11/12", False, 1),
            ):
                with tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / "shard"
                    responses = []
                    for body in bodies:
                        response = io.BytesIO(body)
                        response.status = 206
                        response.headers = {
                            "Content-Range": content_range,
                            "Content-Length": str(len(DATA)),
                        }
                        response.geturl = lambda: url
                        responses.append(response)
                    fetcher = image.RangeFetcher("owner/repo", {7: asset})
                    with (
                        self.subTest(
                            to_file=to_file, bodies=bodies, content_range=content_range
                        ),
                        mock.patch.object(
                            image.urllib.request, "urlopen", side_effect=responses
                        ) as request,
                        mock.patch.object(image.time, "sleep"),
                    ):

                        def download():
                            if to_file:
                                return fetcher.fetch_to(7, 0, len(DATA) - 1, path)
                            return fetcher.fetch(7, 0, len(DATA) - 1)

                        if succeeds:
                            self.assertEqual(download(), len(DATA) if to_file else DATA)
                            if to_file:
                                self.assertEqual(path.read_bytes(), DATA)
                        else:
                            with self.assertRaisesRegex(
                                ValueError, "invalid range response"
                            ):
                                download()
                            self.assertFalse(path.exists())
                        self.assertEqual(request.call_count, calls)

    def test_upload_reconciles_errors_only_with_matching_uploaded_asset(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "shard.bin"
            path.write_bytes(DATA)
            asset = {
                "id": 10,
                "name": path.name,
                "size": len(DATA),
                "digest": "sha256:" + image.sha256(DATA),
                "state": "uploaded",
            }
            upload_error = subprocess.CalledProcessError(1, ["gh", "release", "upload"])
            cases = [
                (None, [asset], None),
                (upload_error, [asset], None),
                (
                    subprocess.TimeoutExpired(["gh", "release", "upload"], 600),
                    [asset],
                    None,
                ),
            ]
            cases += [
                (upload_error, assets, message)
                for assets, message in (
                    ([], "uploaded asset missing"),
                    ([asset, asset], "uploaded asset missing"),
                    ([{**asset, "name": "other.bin"}], "uploaded asset missing"),
                    ([{**asset, "size": len(DATA) + 1}], "upload integrity mismatch"),
                    (
                        [{**asset, "digest": "sha256:" + "0" * 64}],
                        "upload integrity mismatch",
                    ),
                    ([{**asset, "state": "starter"}], "asset upload incomplete"),
                )
            ]
            for error, assets, message in cases:
                release = {"id": 7, "tag_name": "ci-cache-v1-7", "assets": []}
                fresh = {**release, "assets": assets}
                with (
                    self.subTest(error=error, assets=assets),
                    mock.patch.object(
                        generation, "gh_upload", side_effect=error
                    ) as upload,
                    mock.patch.object(generation, "gh_api", return_value=fresh) as api,
                    mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
                    mock.patch("sys.stderr", new_callable=io.StringIO),
                ):
                    if message:
                        with self.assertRaisesRegex(ValueError, message):
                            generation.upload("owner/repo", release, path)
                        self.assertEqual(release["assets"], [])
                    else:
                        self.assertEqual(
                            generation.upload("owner/repo", release, path),
                            image.identity(asset),
                        )
                        self.assertEqual(release, fresh)
                    upload.assert_called_once_with(
                        "owner/repo", release["tag_name"], path
                    )
                    api.assert_called_once_with("owner/repo", "releases/7")
                    self.assertEqual(stdout.getvalue(), "")

    def test_cached_nix_requires_expected_version_and_registered_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            darwin.write_json(root / "mode.json", {"mode": "hot"})
            env = {
                "HOME": directory,
                "XDG_CONFIG_HOME": directory,
                "NIX_CONF": "build-dir = /tmp/nix-builds",
                "NIX_VERSION": "2.34.7",
                "GITHUB_ACCESS_TOKEN": "fresh-run-token",
            }
            runtime = Path("/nix/store/cached-nix")
            with (
                mock.patch.dict(os.environ, env),
                mock.patch.object(Path, "resolve", return_value=runtime),
                mock.patch.object(Path, "is_file", return_value=True),
                mock.patch.object(darwin, "recovery_ready"),
                mock.patch.object(darwin, "command") as command,
            ):
                command.return_value.stdout = "nix (Nix) 2.34.7\n"
                self.assertTrue(darwin.activate_nix(root))
                self.assertEqual(
                    command.call_args_list[1].args,
                    (runtime / "bin/nix-store", "--check-validity", runtime),
                )
                self.assertIn(
                    "access-tokens = github.com=fresh-run-token",
                    (root / "nix/nix.conf").read_text(),
                )
                self.assertEqual((root / ".netrc").stat().st_mode & 0o777, 0o600)
                command.reset_mock()
                command.return_value.stdout = "nix (Nix) 2.33.0\n"
                self.assertFalse(darwin.activate_nix(root))
                self.assertEqual(command.call_count, 1)
                command.side_effect = [
                    mock.Mock(stdout="nix (Nix) 2.34.7\n"),
                    subprocess.CalledProcessError(1, []),
                ]
                self.assertFalse(darwin.activate_nix(root))

    def test_real_pack_manifest_rejects_mutated_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            _, manifest = packed(Path(directory))
            mutations = (
                lambda value: value.update(imageBytes=True),
                lambda value: value["shards"][0].update(name="../escape"),
                lambda value: value["shards"][1].update(offset=9),
                lambda value: value["shards"][0]["blocks"][0].update(sha256="bad"),
            )
            for mutate in mutations:
                value = copy.deepcopy(manifest)
                mutate(value)
                with self.assertRaises(ValueError):
                    image.validate_manifest(value)

    def test_hot_zip_and_uncached_backing_verify_actual_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, manifest = packed(root)
            store = image.BlockStore(manifest, root / "reader", local_image=source)
            profile = root / "profile"
            profile.write_text("0\n1\n")
            hot = root / "hot.zip"
            image.pack_hot(source, root / "packed" / image.DRAFT_NAME, profile, hot)
            self.assertEqual(image.import_hot_pack(hot, store), (2, 8))
            self.assertEqual(store.read(0, 4), b"abcd")
            bad = root / "bad.zip"
            with zipfile.ZipFile(hot) as original, zipfile.ZipFile(bad, "w") as corrupt:
                corrupt.comment = original.comment
                for index, name in enumerate(original.namelist()):
                    data = original.read(name)
                    corrupt.writestr(name, b"X" * len(data) if index == 0 else data)
            with self.assertRaisesRegex(ValueError, "hot-pack block digest mismatch"):
                image.import_hot_pack(bad, store)
            source.write_bytes(b"abcdefghWXYZ")
            with self.assertRaisesRegex(ValueError, "block digest mismatch"):
                store.read(8, 4)

    def test_generation_requires_exact_components_and_identities(self):
        valid = complete_generation()
        generation.validate_generation(valid)
        mutations = (
            lambda value: value["components"].pop(generation.COMPONENTS[0]),
            lambda value: value["components"][generation.COMPONENTS[0]].update(
                name="wrong.json"
            ),
            lambda value: value["components"][generation.COMPONENTS[0]].update(
                sha256="bad"
            ),
            lambda value: value["components"][generation.COMPONENTS[1]].update(
                assetId=value["components"][generation.COMPONENTS[0]]["assetId"]
            ),
        )
        for mutate in mutations:
            value = copy.deepcopy(valid)
            mutate(value)
            with self.assertRaises(ValueError):
                generation.validate_generation(value)

    def test_retirement_expires_each_generation_and_protects_current_previous(self):
        now = 200_000
        releases = [
            {
                "id": i,
                "tag_name": f"ci-cache-v1-{i}",
                "draft": False,
                "assets": [{"name": "promotion.json"}],
            }
            for i in range(1, 7)
        ]
        releases[4]["draft"] = True
        releases[5]["assets"] = []
        journals = {}
        for i in range(1, 5):
            intent = {"releaseId": i, "previousId": i - 1 or None, "publisherRunId": 9}
            journals[i] = {
                "schema": generation.PROMOTION_SCHEMA,
                "promotionIntent": intent,
                "promotion": {
                    **intent,
                    "intentSha256": image.sha256(
                        json.dumps(
                            intent, sort_keys=True, separators=(",", ":")
                        ).encode()
                    ),
                    "promotedAt": now - generation.GRACE,
                },
            }
        journals[2]["promotion"]["promotedAt"] += 1  # Not quite 24 hours old.
        journals[4]["promotion"]["promotedAt"] = (
            now  # New promotions must not reset older ages.
        )
        for release in releases[:4]:
            release["assets"] = []
            release["body"] = json.dumps(journals[release["id"]])
        with (
            mock.patch.object(generation, "publisher_context", return_value=9),
            mock.patch.object(generation, "check_run"),
            mock.patch.object(generation, "verify_proof"),
            mock.patch.object(generation, "gh_api", return_value=releases[3]),
            mock.patch.object(
                generation, "load_generation", return_value=(complete_generation(), {})
            ),
            mock.patch.object(generation, "release_inventory", return_value=releases),
            mock.patch.object(generation, "tag_ref", return_value=None),
            mock.patch.object(generation.time, "time", return_value=now),
            mock.patch.object(generation, "delete_release_and_tag") as delete,
        ):
            source = complete_generation()["source"]
            self.assertEqual(
                generation.prune("owner/repo", source),
                {"releaseIds": [1], "executed": False},
            )
            delete.assert_not_called()
            journals[2]["promotion"]["promotedAt"] -= 1
            releases[1]["body"] = json.dumps(journals[2])
            self.assertEqual(
                generation.prune("owner/repo", source, execute=True),
                {"releaseIds": [1, 2], "executed": True},
            )
            self.assertEqual(
                [call.args[1]["id"] for call in delete.call_args_list], [1, 2]
            )
            delete.reset_mock()
            journals[1]["promotion"]["intentSha256"] = "0" * 64
            releases[0]["body"] = json.dumps(journals[1])
            with self.assertRaisesRegex(ValueError, "invalid promotion record"):
                generation.prune("owner/repo", source, execute=True)
            delete.assert_not_called()

    def test_tag_cleanup_retries_transient_failures_but_refuses_changed_target(self):
        original = {"object": {"type": "commit", "sha": "a" * 40}}
        changed = {"object": {"type": "commit", "sha": "b" * 40}}
        with (
            mock.patch.object(
                generation,
                "tag_ref",
                side_effect=[subprocess.CalledProcessError(1, []), original, changed],
            ),
            mock.patch.object(
                generation,
                "gh_api",
                side_effect=[None, subprocess.TimeoutExpired([], 60)],
            ) as api,
            self.assertRaisesRegex(ValueError, "orphan tag ci-cache-v1-7 changed"),
        ):
            generation.delete_release_and_tag(
                "owner/repo", {"id": 7, "tag_name": "ci-cache-v1-7"}, original
            )
        self.assertEqual(
            api.call_args_list,
            [
                mock.call("owner/repo", "releases/7", "DELETE"),
                mock.call("owner/repo", "git/refs/tags/ci-cache-v1-7", "DELETE"),
            ],
        )

    def test_candidate_cleanup_requires_owned_finished_work_and_grace(self):
        updated = "2026-09-08T00:00:00Z"
        release = {
            "tag_name": "ci-cache-v1-123001",
            "draft": True,
            "author": {"login": "whitestrake[bot]"},
            "target_commitish": "a" * 40,
            "updated_at": updated,
        }
        run = {
            "id": 123,
            "run_attempt": 2,
            "status": "completed",
            "conclusion": "success",
            "path": generation.PUBLISHER,
            "head_repository": {"full_name": "owner/repo"},
            "head_sha": "a" * 40,
            "updated_at": updated,
        }
        boundary = (
            generation.datetime.fromisoformat(updated).timestamp() + generation.GRACE
        )

        def ready(r, w, t=boundary):
            return generation.candidate_ready(r, w, "owner/repo", t)

        self.assertTrue(
            ready(release, run)
        )  # Successful rerun leaves the older draft eligible.
        self.assertFalse(ready(release, run, boundary - 1))
        sealed = {**release, "draft": False, "prerelease": True}
        master_run = {**run, "head_branch": "master"}
        self.assertTrue(ready(sealed, master_run))
        self.assertFalse(ready(sealed, master_run, boundary - 1))
        self.assertFalse(ready(sealed, run))
        branch_run = {**run, "head_branch": "feat/cache-experiment"}
        with mock.patch.object(generation, "gh_api", return_value={}) as api:
            self.assertFalse(ready(sealed, branch_run))
            api.assert_called_once_with(
                "owner/repo", "branches/feat%2Fcache-experiment"
            )
        with mock.patch.object(
            generation,
            "gh_api",
            side_effect=subprocess.CalledProcessError(1, [], stderr=b"HTTP 404"),
        ) as api:
            self.assertTrue(ready(sealed, branch_run, boundary - generation.GRACE))
            api.reset_mock()
            self.assertFalse(ready(sealed, {**branch_run, "status": "in_progress"}))
            self.assertFalse(ready(sealed, {**branch_run, "head_sha": "b" * 40}))
            self.assertFalse(ready(release, branch_run, boundary - 1))
            api.assert_not_called()
        for error in (
            subprocess.CalledProcessError(1, [], stderr=b"HTTP 403"),
            subprocess.TimeoutExpired([], 60),
        ):
            with (
                self.subTest(error=error),
                mock.patch.object(generation, "gh_api", side_effect=error),
                self.assertRaises(type(error)),
            ):
                ready(sealed, branch_run)
        self.assertFalse(ready(sealed, {**master_run, "status": "in_progress"}))
        self.assertFalse(ready({**sealed, "prerelease": False}, master_run))
        self.assertFalse(
            ready({**sealed, "assets": [{"name": "promotion.json"}]}, master_run)
        )
        for field, value in (
            ("draft", False),
            ("author", {"login": "someone"}),
            ("tag_name", "unrelated-123001"),
            ("target_commitish", "b" * 40),
        ):
            self.assertFalse(ready({**release, field: value}, run))
        for field, value in (
            ("status", "in_progress"),
            ("id", 124),
            ("path", "other.yml"),
            ("run_attempt", 0),
        ):
            self.assertFalse(ready(release, {**run, field: value}))
        for body in (
            "{bad",
            json.dumps({"schema": generation.PROMOTION_SCHEMA, "promotion": None}),
            json.dumps(
                {"schema": generation.PROMOTION_SCHEMA, "promotionIntent": None}
            ),
        ):
            with (
                self.subTest(body=body),
                self.assertRaisesRegex(ValueError, "promotion journal"),
            ):
                ready({**release, "body": body}, run)


if __name__ == "__main__":
    unittest.main()
