#!/usr/bin/env python3
import argparse
import json
from collections import defaultdict
from pathlib import Path

COMMENT_MARKER = "<!-- flake-lock-package-report:comment -->"


def load_reports(diff_dir):
    reports = []
    for path in sorted(Path(diff_dir).rglob("record.json")):
        data = json.loads(path.read_text())
        report = data["packageReport"]
        reports.append(
            {
                "name": data["name"],
                "system": data["system"],
                "status": report["status"],
                "message": report["message"],
                "diff": report["diff"],
            }
        )

    if not reports:
        raise SystemExit("no GHCI record.json artifacts found")
    return reports


def version_text(diff):
    old = []
    new = []
    for version in diff["versions"]:
        match version["kind"]:
            case "changed":
                old.append(version["old"]["name"])
                new.append(version["new"]["name"])
            case "added":
                new.append(version["version"]["name"])
            case "removed":
                old.append(version["version"]["name"])
            case "amount_changed":
                name = version["version"]["name"]
                old.append(f"{name} x{version['old_amount']}")
                new.append(f"{name} x{version['new_amount']}")
            case other:
                raise SystemExit(f"unsupported dix version kind: {other}")

    if len(old) != len(new):
        old_text = ", ".join(old)
        new_text = ", ".join(new)
    else:
        pairs = list(zip(old, new))
        pair_set = set(pairs)
        pairs = [
            pair
            for pair in pairs
            if not (
                pair[0].endswith("-modules")
                and pair[1].endswith("-modules")
                and (pair[0][:-8], pair[1][:-8]) in pair_set
            )
        ]
        old_text = ", ".join(pair[0] for pair in pairs)
        new_text = ", ".join(pair[1] for pair in pairs)

    if old_text and new_text:
        return f"{old_text} -> {new_text}"
    if new_text:
        return f"added {new_text}"
    if old_text:
        return f"removed {old_text}"
    return ""


def format_bytes(size):
    sign = "+" if size > 0 else "-"
    value = float(abs(size))
    for unit in ["B", "KiB", "MiB", "GiB", "TiB"]:
        if value < 1024 or unit == "TiB":
            if unit == "B":
                return f"{sign}{int(value)} {unit}"
            return f"{sign}{value:.1f} {unit}"
        value /= 1024


def delta_text(size):
    symbol = ":red_circle:" if size > 0 else ":green_circle:"
    return f"{symbol} {format_bytes(size)}"


def render_package(name, version, entries, host_count):
    label = f"{name}: {version}" if version else f"{name}:"
    by_delta = {}
    for host, size in entries:
        if size != 0:
            text = delta_text(size)
            group = by_delta.setdefault(text, {"hosts": [], "sort": size})
            group["hosts"].append(host)
            group["sort"] = min(group["sort"], size)

    if not by_delta:
        return label if version else None

    only_text, only_group = next(iter(by_delta.items()))
    if len(by_delta) == 1 and len(only_group["hosts"]) == host_count:
        separator = " " if label.endswith(":") else ", "
        return f"{label}{separator}{only_text}"

    lines = [label]
    for text, group in sorted(by_delta.items(), key=lambda item: item[1]["sort"]):
        lines.append(f"  {text} ({', '.join(sorted(group['hosts']))})")
    return "\n".join(lines)


def package_updates(reports):
    packages = defaultdict(list)
    for report in reports:
        for diff in report["diff"]["diffs"]:
            name = diff["name"]
            if name.startswith(("nixos-system-", "darwin-system-")):
                continue
            packages[(name, version_text(diff))].append(
                (report["name"], diff["size_delta"])
            )

    return [
        rendered
        for (name, version), entries in sorted(packages.items())
        if (rendered := render_package(name, version, entries, len(reports)))
    ]


def render(diff_dir, head_sha, base_sha):
    reports = load_reports(diff_dir)
    successful = [report for report in reports if report["status"] == "success"]
    failed = [report for report in reports if report["status"] != "success"]
    updates = package_updates(successful)

    lines = [
        COMMENT_MARKER,
        f"Report generated for `{head_sha}`",
        f"Compared against `{base_sha}`",
        "",
        "## Package updates",
    ]
    lines.extend(f"- {line}" for line in updates)
    if not updates:
        lines.append("- No package updates detected.")

    if failed:
        lines.extend(["", "## Unavailable reports"])
        lines.extend(
            f"- {report['name']} ({report['system']}): {report['message']}"
            for report in failed
        )

    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--diff-dir", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    Path(args.output).write_text(render(args.diff_dir, args.head_sha, args.base_sha))


if __name__ == "__main__":
    main()
