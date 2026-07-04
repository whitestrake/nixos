#!/usr/bin/env python3
import argparse
import json
from collections import Counter
from pathlib import Path

START_MARKER = "<!-- flake-lock-package-report:start -->"
END_MARKER = "<!-- flake-lock-package-report:end -->"


def load_reports(diff_dir):
    return [json.loads(path.read_text()) for path in sorted(Path(diff_dir).rglob("*.json"))]


def render_report(diff_dir, head_sha, base_sha):
    reports = load_reports(diff_dir)
    successful = [r for r in reports if r.get("status") == "success"]
    failed = [r for r in reports if r.get("status") != "success"]
    line_counts = Counter(
        line
        for r in successful
        for line in dict.fromkeys(r.get("diff", []))
        if line.strip()
    )
    common = sorted(line for line, count in line_counts.items() if count > 1)

    lines = [
        f"Report generated for `{head_sha}`",
        f"Compared against `{base_sha}`",
        "",
        "## Package updates",
    ]
    lines.extend(f"- {line}" for line in common)
    if not common:
        lines.append("- No shared package updates detected.")

    for r in successful:
        specific = [
            line
            for line in r.get("diff", [])
            if line.strip() and line_counts[line] == 1
        ]
        if not specific:
            continue
        lines.extend(["", f"## {r['name']} specific"])
        lines.extend(f"- {line}" for line in specific)

    if failed:
        lines.extend(["", "## Unavailable reports"])
        lines.extend(
            f"- {r.get('name', 'unknown')} ({r.get('system', 'unknown')}): {r.get('message', 'report unavailable')}"
            for r in failed
        )

    return "\n".join(lines) + "\n"


def replace_marker_block(body, report):
    start = body.find(START_MARKER)
    end = body.find(END_MARKER)
    block = f"{START_MARKER}\n{report.rstrip()}\n{END_MARKER}"

    if start == -1 or end == -1 or end < start:
        return body.rstrip() + "\n\n" + block + "\n"

    end += len(END_MARKER)
    return body[:start] + block + body[end:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--diff-dir", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--body", required=True)
    parser.add_argument("--output", required=True)

    args = parser.parse_args()
    report = render_report(args.diff_dir, args.head_sha, args.base_sha)
    Path(args.output).write_text(
        replace_marker_block(Path(args.body).read_text(), report)
    )


if __name__ == "__main__":
    main()
