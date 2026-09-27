#!/usr/bin/env python3
"""Focused checks for the Proxmox MCP Plus release decision."""

import unittest
from email.message import Message
from unittest.mock import patch

import select_proxmox_mcp_plus as selector


def metadata(version, *requirements, python=">=3.11"):
    result = Message()
    result["Name"] = "proxmox-mcp-plus"
    result["Version"] = version
    result["Requires-Python"] = python
    for requirement in requirements:
        result["Requires-Dist"] = requirement
    return result


def context(mcp="1.26.0", python="3.13.15"):
    return {
        "x86_64-linux": {
            "version": "0.5.20",
            "python": python,
            "dependencies": [
                {"name": "mcp", "version": mcp},
                {"name": "paramiko", "version": "4.0"},
            ],
            "relax": ["paramiko"],
            "remove": ["mcpo"],
        }
    }


def index(*versions):
    return {"releases": {version: [{"yanked": False}] for version in versions}}


class SelectorChecks(unittest.TestCase):
    def test_known_mismatch_skips_and_dependencies_catching_up_resumes(self):
        releases = index("0.5.21", "0.5.22")
        details = {
            "0.5.21": metadata("0.5.21", "mcp>=1.20"),
            "0.5.22": metadata("0.5.22", "mcp>=1.30"),
        }

        def fetch(files):
            return details[
                next(
                    key for key, value in releases["releases"].items() if value is files
                )
            ]

        self.assertEqual(selector.select(releases, context(), fetch), "0.5.21")
        self.assertEqual(selector.select(releases, context("1.30.0"), fetch), "0.5.22")

    def test_new_dependency_allowed_and_combined_case_defers(self):
        new = metadata("0.5.22", "asyncpg>=0.30")
        both = metadata("0.5.22", "asyncpg>=0.30", "mcp>=1.30")
        self.assertEqual(selector.assess(new, context())[0], [])
        self.assertEqual(len(selector.assess(new, context())[1]), 1)
        self.assertEqual(
            selector.select(index("0.5.22"), context(), lambda _: new), "0.5.22"
        )
        incompatible, undeclared = selector.assess(both, context())
        self.assertEqual(len(incompatible), 1)
        self.assertEqual(len(undeclared), 1)
        self.assertEqual(
            selector.select(index("0.5.22"), context(), lambda _: both), ""
        )

    def test_relax_remove_markers_and_python(self):
        candidate = metadata(
            "0.5.22",
            "paramiko<3",
            "mcpo>=9",
            "winonly; sys_platform == 'win32'",
            "optional; extra == 'proxy'",
            "mcp>=1.20; python_version >= '3.13'",
            "mcp>=1.20; implementation_version < '3.14'",
        )
        self.assertEqual(selector.assess(candidate, context()), ([], []))
        incompatible, _ = selector.assess(
            metadata("0.5.22", python=">=3.14"), context()
        )
        self.assertIn("Python", incompatible[0])
        with self.assertRaisesRegex(ValueError, "target kernel marker"):
            selector.assess(
                metadata("0.5.22", "mcp; platform_release >= '5'"), context()
            )
        contexts = context()
        contexts["aarch64-darwin"] = dict(contexts["x86_64-linux"])
        incompatible, _ = selector.assess(
            metadata("0.5.22", "mcp>=1.30; sys_platform == 'darwin'"), contexts
        )
        self.assertEqual(len(incompatible), 1)
        self.assertIn("aarch64-darwin", incompatible[0])

    def test_no_downgrade_yanked_and_no_eligible_release(self):
        with patch.object(selector, "release_metadata") as fetch:
            self.assertEqual(
                selector.select(index("0.5.19", "0.5.20"), context(), fetch), ""
            )
            fetch.assert_not_called()
        self.assertEqual(
            selector.select({"releases": {"0.5.22": [{"yanked": True}]}}, context()), ""
        )

    def test_metadata_failure_is_fatal(self):
        with self.assertRaisesRegex(ValueError, "metadata unavailable"):
            selector.select(
                index("0.5.22"),
                context(),
                lambda _: (_ for _ in ()).throw(ValueError("metadata unavailable")),
            )


if __name__ == "__main__":
    unittest.main()
