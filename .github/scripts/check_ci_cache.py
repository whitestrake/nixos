#!/usr/bin/env python3
"""Small portable checks for cache data and retention boundaries."""

import copy
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

import ci_cache_generation as generation
import ci_cache_image as image


DATA = b"abcdefghijkl"


def packed(root):
    source = root / "image"
    source.write_bytes(DATA)
    output = root / "packed"
    image.pack_image(source, output, shard_size=8, block_size=4)
    manifest = json.loads((output / image.DRAFT_NAME).read_text())
    manifest["releaseId"] = 7
    assets = {}
    for asset_id, shard in enumerate(manifest["shards"], 10):
        shard["assetId"] = asset_id
        assets[asset_id] = {
            "id": asset_id,
            "name": shard["name"],
            "size": shard["size"],
            "digest": "sha256:" + shard["sha256"],
            "browser_download_url": "",
        }
    image.validate_manifest(manifest)
    return source, manifest, assets


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
    def test_real_pack_manifest_rejects_mutated_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            _, manifest, _ = packed(Path(directory))
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
            source, manifest, _ = packed(root)
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

    def test_retirement_keeps_current_previous_and_full_grace(self):
        promoted_at = 100_000
        releases = [
            {
                "id": release_id,
                "tag_name": f"ci-cache-v1-{release_id}",
                "draft": False,
                "assets": [{"name": "promotion.json"}],
            }
            for release_id in range(1, 6)
        ]
        releases[-1]["assets"] = []  # Never promoted; not eligible for retirement.
        current = {"releaseId": 4, "previousId": 3, "promotedAt": promoted_at}
        before_grace = promoted_at + generation.GRACE - 1
        at_grace = promoted_at + generation.GRACE
        self.assertEqual(
            generation.retirement_plan(releases, current, before_grace), []
        )
        self.assertEqual(
            generation.retirement_plan(releases, current, at_grace), [1, 2]
        )
        current.update(releaseId=5, previousId=4, promotedAt=at_grace)
        self.assertEqual(generation.retirement_plan(releases, current, at_grace), [])


if __name__ == "__main__":
    unittest.main()
