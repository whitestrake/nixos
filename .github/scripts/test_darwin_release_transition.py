"""Local state checks for the one-shot Darwin Release transition probe."""

import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "transition", Path(__file__).with_name("darwin-release-transition.py")
)
TRANSITION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRANSITION)


class TransitionChecks(unittest.TestCase):
    def test_latest_must_be_the_exact_expected_published_release(self):
        release = {
            "id": 383622742,
            "tag_name": "darwin-release-v1-expected",
            "draft": False,
            "prerelease": False,
        }
        TRANSITION.require_latest(release, 383622742)
        for change in (
            {"id": 99},
            {"draft": True},
            {"prerelease": True},
        ):
            with self.subTest(change=change), self.assertRaises(AssertionError):
                TRANSITION.require_latest({**release, **change}, 383622742)

    def test_owned_draft_requires_exact_identity_and_one_expected_asset(self):
        asset = {
            "id": 44,
            "name": "image-successor-00003.bin",
            "size": 19,
            "digest": "sha256:" + "a" * 64,
        }
        release = {
            "id": 33,
            "tag_name": "pr158-e49-transition-123-1",
            "target_commitish": TRANSITION.RELEASE_TARGET_SHA,
            "draft": True,
            "prerelease": False,
            "assets": [asset],
        }
        TRANSITION.require_owned_draft(
            release,
            release_id=33,
            tag=release["tag_name"],
            asset=asset,
        )
        TRANSITION.require_owned_draft(
            {**release, "assets": []},
            release_id=33,
            tag=release["tag_name"],
            asset=asset,
            allow_missing_asset=True,
        )
        mutations = (
            {"id": 34},
            {"tag_name": "someone-elses-tag"},
            {"target_commitish": "0" * 40},
            {"draft": False},
            {"assets": []},
            {"assets": [asset, {**asset, "id": 45, "name": "manifest.json"}]},
            {"assets": [{**asset, "digest": "sha256:" + "b" * 64}]},
        )
        for change in mutations:
            with self.subTest(change=change), self.assertRaises(AssertionError):
                TRANSITION.require_owned_draft(
                    {**release, **change},
                    release_id=33,
                    tag=release["tag_name"],
                    asset=asset,
                )

        TRANSITION.require_empty_owned_draft(
            {**release, "assets": []}, 33, release["tag_name"]
        )
        with self.assertRaises(AssertionError):
            TRANSITION.require_empty_owned_draft(release, 33, release["tag_name"])

    def test_three_phase_blocks_are_distinct_and_spread_across_image(self):
        indices = TRANSITION.phase_block_indices(10)
        self.assertEqual(indices, [0, 5, 9])
        self.assertEqual(len(indices), len(set(indices)))
        with self.assertRaises(AssertionError):
            TRANSITION.phase_block_indices(2)

    def test_owned_tag_format_is_narrow(self):
        TRANSITION.require_owned_tag("pr158-e49-transition-34000000000-1")
        for tag in (
            "pr158-e49-transition-static",
            "pr158-e49-transition-34000000000-1/extra",
            "darwin-release-v1-34000000000-1",
        ):
            with self.subTest(tag=tag), self.assertRaises(AssertionError):
                TRANSITION.require_owned_tag(tag)

    def test_owned_tag_must_not_exist_before_creation(self):
        tag = "pr158-e49-transition-34000000000-1"
        with patch.object(TRANSITION, "exact_tag_ref", return_value=None):
            TRANSITION.require_unused_owned_tag("owner/repo", tag)
        with (
            patch.object(
                TRANSITION,
                "exact_tag_ref",
                return_value={"ref": f"refs/tags/{tag}"},
            ),
            self.assertRaises(AssertionError),
        ):
            TRANSITION.require_unused_owned_tag("owner/repo", tag)

    def test_cleanup_deletes_verified_tag_before_draft(self):
        tag = "pr158-e49-transition-34000000000-1"
        asset = {
            "id": 44,
            "name": "image-successor-00003.bin",
            "size": 19,
            "digest": "sha256:" + "a" * 64,
        }
        release = {
            "id": 33,
            "tag_name": tag,
            "target_commitish": TRANSITION.RELEASE_TARGET_SHA,
            "draft": True,
            "prerelease": False,
            "assets": [asset],
        }
        calls = []

        def api(_repo, endpoint, method="GET", payload=None):
            calls.append((endpoint, method, payload))
            if endpoint == "releases/33":
                return release
            return None

        tag_ref = {
            "ref": f"refs/tags/{tag}",
            "object": {"type": "commit", "sha": TRANSITION.RELEASE_TARGET_SHA},
        }
        with (
            patch.object(TRANSITION.IMAGE, "gh_api", side_effect=api),
            patch.object(TRANSITION, "exact_tag_ref", return_value=tag_ref),
        ):
            result = TRANSITION.cleanup_owned_draft("owner/repo", 33, tag, asset)
        self.assertEqual(result, {"releaseDeleted": True, "tag": "deleted"})
        self.assertEqual(
            calls,
            [
                ("releases/33", "GET", None),
                (f"git/refs/tags/{tag}", "DELETE", None),
                ("releases/33", "DELETE", None),
            ],
        )


if __name__ == "__main__":
    unittest.main()
