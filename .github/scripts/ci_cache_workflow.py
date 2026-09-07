#!/usr/bin/env python3
"""Small shared plumbing for the complete-generation workflow."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

import ci_cache_generation as generation
import ci_cache_image as image

SYSTEMS = ("x86_64-linux", "aarch64-linux", "aarch64-darwin")
STORE_PATH = re.compile(
    r"/nix/store/([0123456789abcdfghijklmnpqrsvwxyz]{32})-[A-Za-z0-9+._?=-]+"
)


def run(*argv):
    return subprocess.check_output(argv, text=True).strip()


def write(path, value):
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")


def input_paths(archive, prefix=""):
    result = {}
    for name, entry in sorted(archive.get("inputs", {}).items()):
        key = prefix + name
        result[key] = entry["path"]
        result.update(input_paths(entry, key + "/"))
    return result


def evaluator_inputs(before, after, excluded):
    result = {}
    for path in sorted(set(after) - set(before) - set(excluded)):
        if path.endswith(".drv"):
            continue
        match = STORE_PATH.fullmatch(path)
        image.require(match is not None, "unsafe evaluator input path: " + path)
        result["evaluator/" + match[1]] = path
    return result


def coverages(proof, inputs, nfb, definitions):
    inputs = dict(sorted(inputs.items()))
    parts = {}
    for component in generation.COMPONENTS:
        system = next(system for system in SYSTEMS if component.endswith(system))
        roots = set(inputs.values()) | {nfb[system]}
        if not component.startswith("linux-seed-"):
            roots.update(
                r["storePath"] for r in proof["records"] if r["system"] == system
            )
        parts[component] = {
            "roots": sorted(roots),
            "inputs": inputs,
            "tools": {**definitions, "nix-fast-build/" + system: nfb[system]},
        }
    total = {"roots": [], "inputs": {}, "tools": {}}
    for part in parts.values():
        total["roots"].extend(part["roots"])
        for field in ("inputs", "tools"):
            total[field].update(part[field])
    total["roots"] = sorted(set(total["roots"]))
    return total, parts


def plan(directory, proof_path, run_id, release_id=None):
    directory.mkdir()
    raw = subprocess.check_output(
        ["nix", "store", "cat", "--store", "https://whitestrake.cachix.org", proof_path]
    )
    proof = json.loads(
        subprocess.check_output(
            ["jq", "-ceS", "-f", ".github/scripts/ci-build-proof.jq"], input=raw
        )
    )
    revision = run("git", "rev-parse", "HEAD")
    image.require(proof["revision"] == revision, "proof does not match checkout")
    source = {
        "revision": revision,
        "runId": run_id,
        "proof": {"storePath": proof_path, "sha256": hashlib.sha256(raw).hexdigest()},
    }
    generation.check_run(
        os.environ["GITHUB_REPOSITORY"],
        run_id,
        revision,
        generation.SOURCE_WORKFLOW,
        successful=True,
    )
    archive = json.loads(run("nix", "flake", "archive", "--json", "path:."))
    inputs = input_paths(archive)
    checkout = json.loads(run("nix", "flake", "metadata", "--json", "."))["path"]
    checkout_roots = {archive["path"], checkout}
    image.require(
        inputs
        and not checkout_roots.intersection(inputs.values())
        and all(
            STORE_PATH.fullmatch(path) for path in [*inputs.values(), *checkout_roots]
        ),
        "invalid external input roots",
    )
    before = run("nix-store", "--query", "--all").splitlines()
    nfb = {
        system: run(
            "nix", "eval", "--raw", f".#packages.{system}.nix-fast-build.outPath"
        )
        for system in SYSTEMS
    }
    after = run("nix-store", "--query", "--all").splitlines()
    realised = evaluator_inputs(before, after, [*inputs.values(), *checkout_roots])
    image.require(not inputs.keys() & realised.keys(), "evaluator input name collision")
    inputs.update(realised)
    print(f"NIX_EVALUATOR_INPUTS_CAPTURED count={len(realised)}")
    for path in realised.values():
        print(f"NIX_EVALUATOR_INPUT path={path}")
    definitions = {
        path: run("git", "rev-parse", "HEAD:" + path)
        for path in (
            "packages/nix-fast-build.nix",
            "modules/ci.nix",
            ".github/scripts/ci_cache_image.py",
            ".github/scripts/ci_darwin.py",
            ".github/scripts/ci-linux-image.sh",
            ".github/scripts/ci_cache_workflow.py",
            ".github/scripts/ci-nfb.sh",
            ".github/actions/ci-darwin-prepare/action.yml",
            ".github/actions/install-nix/action.yml",
            ".github/actions/nix-root-build/action.yml",
        )
    }
    definitions["cachix-action"] = "38b082610b782e7e93e209c35fd730d399dee866"
    coverage, parts = coverages(proof, inputs, nfb, definitions)
    write(directory / "source.json", source)
    write(directory / "proof.json", proof)
    write(directory / "coverage.json", coverage)
    for component, part in parts.items():
        write(directory / (component + ".json"), part)
    for system in SYSTEMS:
        write(
            directory / (system + "-records.json"),
            [r for r in proof["records"] if r["system"] == system],
        )
    refresh = True
    selection = directory / "previous.json"
    try:
        previous = generation.resolve(
            os.environ["GITHUB_REPOSITORY"], selection, release_id
        )
    except (ValueError, KeyError, subprocess.CalledProcessError):
        if release_id is not None:
            raise
        print("No usable previous generation; rebuilding all components.")
    else:
        refresh = generation.fingerprint(
            previous["generation"]["coverage"]
        ) != generation.fingerprint(coverage)
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        stream.write(
            f"refresh={'true' if refresh or os.environ.get('FORCE_REBUILD') == 'true' else 'false'}\n"
        )


def verify(coverage, system, deep=True):
    roots = Path("/nix/var/nix/gcroots/github-ci") / system
    retained = {str(path.resolve()) for path in roots.iterdir() if path.is_symlink()}
    image.require(
        set(coverage["roots"]) <= retained, "expected canonical roots missing"
    )
    paths = subprocess.check_output(
        ["nix", "path-info", "--recursive", *coverage["roots"]],
        text=True,
    ).splitlines()
    image.require(
        paths and all(os.path.lexists(path) for path in paths),
        "expected closure paths missing",
    )
    if not deep:
        return
    subprocess.run(
        ["nix", "store", "verify", "--recursive", "--no-trust", *coverage["roots"]],
        check=True,
    )
    nfb = roots / "nix-fast-build/bin/nix-fast-build"
    subprocess.run([str(nfb), "--help"], check=True, stdout=subprocess.DEVNULL)


def receipt(selection_path, component, directory):
    selection = generation.read_selection(
        selection_path, os.environ["GITHUB_REPOSITORY"]
    )
    current = selection["generation"]
    pin = current["components"][component]
    directory.mkdir()
    manifest, _ = image.load_manifest(
        selection["repo"], current["releaseId"], pin, directory / "manifest"
    )
    system = next(system for system in SYSTEMS if component.endswith(system))
    if component.startswith("darwin-"):
        state = Path(os.environ["RUNNER_TEMP"]) / "darwin"
        image.require(
            json.loads((state / "selection.json").read_text()) == selection,
            "mounted Darwin generation differs",
        )
        mode = json.loads((state / "mode.json").read_text())["mode"]
        image.require(
            mode == ("hot" if component.startswith("darwin-image-") else "maintenance"),
            "candidate reader fell back to another component",
        )
        if mode == "hot":
            image.require(
                (state / "selected/records.json").is_file(),
                "missing successful hot workload",
            )
            image.require(
                not (state / "reader/backing-failure").exists(), "hot backing failed"
            )
    else:
        image.require(
            os.environ.get("CI_LINUX_CACHE_RESTORED") == "true",
            "candidate image was not restored",
        )
        mounted = Path(os.environ["CI_LINUX_CACHE_IMAGE"])
        image.require(mounted.is_file(), "mounted image missing")
        restored = json.loads((mounted.parent / "eager.json").read_text())
        image.require(
            restored["releaseId"] == current["releaseId"]
            and restored["manifestSha256"] == pin["sha256"]
            and restored["imageSha256"] == manifest["imageSha256"],
            "mounted Linux component differs",
        )
    verify(manifest["coverage"], system)
    result = {
        "schema": "ci-cache-reader-receipt-v1",
        "releaseId": current["releaseId"],
        "component": component,
        "manifestSha256": pin["sha256"],
        "imageSha256": manifest["imageSha256"],
        "freshReader": True,
        "verified": True,
    }
    if component.startswith("darwin-image-"):
        result.update(
            filesystemVerified=True, hotPackSha256=manifest["hotPack"]["sha256"]
        )
    write(directory / "receipt.json", result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    p = sub.add_parser("plan")
    p.add_argument("directory", type=Path)
    p.add_argument("proof")
    p.add_argument("run_id", type=int)
    p.add_argument("--release-id", type=int)
    p = sub.add_parser("bind")
    p.add_argument("directory", type=Path)
    p.add_argument("coverage", type=Path)
    for operation in ("check-roots", "verify"):
        p = sub.add_parser(operation)
        p.add_argument("coverage", type=Path)
        p.add_argument("system", choices=SYSTEMS)
    p = sub.add_parser("receipt")
    p.add_argument("selection", type=Path)
    p.add_argument("component", choices=generation.COMPONENTS)
    p.add_argument("directory", type=Path)
    args = parser.parse_args()
    if args.operation == "plan":
        plan(args.directory, args.proof, args.run_id, args.release_id)
    elif args.operation == "bind":
        manifest = args.directory / "draft-manifest.json"
        value = json.loads(manifest.read_text())
        value["coverage"] = json.loads(args.coverage.read_text())
        write(manifest, value)
    elif args.operation in ("check-roots", "verify"):
        verify(
            json.loads(args.coverage.read_text()),
            args.system,
            deep=args.operation == "verify",
        )
    else:
        receipt(args.selection, args.component, args.directory)


if __name__ == "__main__":
    main()
