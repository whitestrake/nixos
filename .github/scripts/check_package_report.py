#!/usr/bin/env python3
"""Focused, portable checks for package report rendering."""

import unittest

import flake_lock_package_report as renderer

BASE = "a" * 40
HEAD = "b" * 40


class PackageReportChecks(unittest.TestCase):
    def test_report_text_cannot_create_markdown(self):
        rendered = renderer.render(
            [
                {
                    "name": "host\n## forged heading",
                    "system": "x86_64-linux",
                    "status": "failed",
                    "message": "<script>surprise</script> https://example.invalid ~~obsolete~~",
                    "diff": None,
                }
            ],
            BASE,
            HEAD,
        )
        self.assertNotIn("\n## forged heading", rendered)
        self.assertNotIn("<script>", rendered)
        self.assertIn("https\\://example\\.invalid", rendered)
        self.assertIn("\\~\\~obsolete\\~\\~", rendered)


if __name__ == "__main__":
    unittest.main()
