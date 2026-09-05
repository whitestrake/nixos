#!/usr/bin/env python3
"""Disposable CI-runner probe for current input and tool identities."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.parse


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def info(path):
    return json.loads(run("nix", "path-info", "--json", path))[path]


def reference(path):
    return (
        "path:"
        + path
        + "?narHash="
        + urllib.parse.quote(info(path)["narHash"], safe="")
    )


def inputs(archive):
    paths = set()

    def visit(node):
        if isinstance(node, dict):
            if "path" in node:
                paths.add(node["path"])
            for value in node.values():
                visit(value)

    visit(archive["inputs"])
    return paths


output = Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
started = time.monotonic()
metadata = json.loads(
    run(
        "nix",
        "flake",
        "metadata",
        "--json",
        "--no-update-lock-file",
        "--option",
        "lazy-trees",
        "false",
        ".",
    )
)
source = reference(metadata["path"])
baseline = inputs(
    json.loads(run("nix", "flake", "archive", "--dry-run", "--json", source))
)
identity_seconds = time.monotonic() - started
assert len(baseline) == 20, baseline
with tempfile.TemporaryDirectory(prefix="ci-input-probe-") as directory:
    Path(directory, "identity.txt").write_text("synthetic input identity probe\n")
    path = run("nix", "store", "add-path", "--name", "source", directory)
    changed = inputs(
        json.loads(
            run(
                "nix",
                "flake",
                "archive",
                "--dry-run",
                "--json",
                "--override-input",
                "whitestrake-github-keys",
                reference(path),
                source,
            )
        )
    )
    assert changed - baseline == {path}, changed - baseline
    assert len(baseline - changed) == 1

# The synthetic input is used only for identity enumeration, never a host build.
tool_attr = ".#packages.x86_64-linux.nix-fast-build"
old_tool = run("nix", "build", "--no-link", "--print-out-paths", tool_attr)
package = Path("packages/nix-fast-build.nix")
original = package.read_text()
needle = "      substituteInPlace nix_fast_build/options.py"
assert original.count(needle) == 1
package.write_text(
    original.replace(
        needle,
        "      echo '# Fast CI changed-tool probe' >> nix_fast_build/options.py\n"
        + needle,
    )
)
new_tool = run("nix", "build", "--no-link", "--print-out-paths", tool_attr)
assert new_tool != old_tool, (old_tool, new_tool)
assert (
    "Fast CI changed-tool probe"
    in next(
        Path(new_tool).glob("lib/python*/site-packages/nix_fast_build/options.py")
    ).read_text()
)
subprocess.run(
    ["nix", "run", tool_attr, "--", "--help"], check=True, stdout=subprocess.DEVNULL
)
result = {
    "nixVersion": run("nix", "--version"),
    "baselineInputs": sorted(baseline),
    "newSelectedInputs": sorted(changed - baseline),
    "removedSelectedInputs": sorted(baseline - changed),
    "currentIdentitySeconds": identity_seconds,
    "oldTool": old_tool,
    "newTool": new_tool,
    "newToolClosure": run("nix", "path-info", "--recursive", new_tool).splitlines(),
}
(output / "identity.json").write_text(json.dumps(result, indent=2) + "\n")
print(
    json.dumps(
        {
            key: value
            for key, value in result.items()
            if key not in {"baselineInputs", "newToolClosure"}
        }
    )
)
