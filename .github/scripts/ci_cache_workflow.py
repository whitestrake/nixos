#!/usr/bin/env python3
"""Small shared plumbing for the complete-generation workflow."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

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
        source = Path(path)
        # ponytail: conventional Nix entry points only; widen on a demonstrated miss.
        if not source.is_dir() or not any(
            (source / name).is_file() for name in ("flake.nix", "default.nix")
        ):
            continue
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
    before = run("nix", "path-info", "--all").splitlines()
    nfb = {
        system: run(
            "nix", "eval", "--raw", f".#packages.{system}.nix-fast-build.outPath"
        )
        for system in SYSTEMS
    }
    after = run("nix", "path-info", "--all").splitlines()
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
        stream.write(
            "reader_matrix="
            + json.dumps({"include": generation.READERS}, separators=(",", ":"))
            + "\n"
        )


def verify(coverage, system, deep=False):
    print(
        f"CI_CACHE_VALIDATION system={system} exhaustive_checks={str(deep).lower()}",
        flush=True,
    )
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
    nfb = roots / "nix-fast-build/bin/nix-fast-build"
    subprocess.run([str(nfb), "--help"], check=True, stdout=subprocess.DEVNULL)
    if deep:
        subprocess.run(
            ["nix", "store", "verify", "--recursive", "--no-trust", *coverage["roots"]],
            check=True,
        )


def retain(coverage, records, system):
    roots = Path("/nix/var/nix/gcroots/github-ci") / system
    desired = {}
    for record in records:
        name, path = record["name"], record["storePath"]
        image.require(
            re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_-]*", name)
            and name != "nix-fast-build"
            and not name.startswith("flake-input-")
            and name not in desired
            and STORE_PATH.fullmatch(path),
            "unsafe or duplicate host root",
        )
        desired[name] = path
    nfb = run(
        "nix",
        "build",
        "--no-link",
        "--print-out-paths",
        "--option",
        "builders",
        "",
        "--option",
        "max-jobs",
        "auto",
        f".#packages.{system}.nix-fast-build",
    )
    image.require(
        nfb == coverage["tools"]["nix-fast-build/" + system], "tool differs from plan"
    )
    desired["nix-fast-build"] = nfb
    # Materialise the checkout's inputs; the authenticated plan owns their selection.
    run("nix", "flake", "archive", "--json", "path:.")
    for path in coverage["inputs"].values():
        match = STORE_PATH.fullmatch(path)
        image.require(match is not None, "unsafe planned input")
        desired["flake-input-" + match[1]] = path
    run("nix", "path-info", *desired.values())
    roots.mkdir(parents=True, exist_ok=True)
    for name, path in desired.items():
        target = roots / name
        image.require(
            not target.exists() or target.is_symlink(),
            "refusing to replace a non-symlink root",
        )
        temporary = roots / f".{name}.{os.getpid()}"
        temporary.symlink_to(path)
        temporary.replace(target)
    for path in roots.iterdir():
        if path.is_symlink() and path.name not in desired:
            path.unlink()
    legacy = Path("/nix/var/nix/gcroots/ghci-cache-lanes") / system
    if legacy.is_dir():
        for path in legacy.iterdir():
            if path.is_symlink():
                path.unlink()
        if not any(legacy.iterdir()):
            legacy.rmdir()
    print(f"CI_ROOTS_RETAINED system={system} count={len(desired)}")


def reader(selection_path, component, deep=False):
    selection = generation.read_selection(
        selection_path, os.environ["GITHUB_REPOSITORY"]
    )
    current = selection["generation"]
    pin = current["components"][component]
    with tempfile.TemporaryDirectory(dir=os.environ["RUNNER_TEMP"]) as directory:
        manifest, _ = image.load_manifest(
            selection["repo"], current["releaseId"], pin, Path(directory) / "manifest"
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
    verify(manifest["coverage"], system, deep=deep)
    print(
        f"CI_CACHE_READER_VERIFIED component={component} releaseId={current['releaseId']}"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    p = sub.add_parser("plan")
    p.add_argument("directory", type=Path)
    p.add_argument("proof")
    p.add_argument("run_id", type=int)
    p.add_argument("--release-id", type=int)
    p = sub.add_parser("retain")
    p.add_argument("coverage", type=Path)
    p.add_argument("records", type=Path)
    p.add_argument("system", choices=SYSTEMS)
    for operation in ("check-roots", "verify"):
        p = sub.add_parser(operation)
        p.add_argument("coverage", type=Path)
        p.add_argument("system", choices=SYSTEMS)
        if operation == "verify":
            p.add_argument("--exhaustive-checks", action="store_true")
    p = sub.add_parser("reader")
    p.add_argument("selection", type=Path)
    p.add_argument("component", choices=generation.COMPONENTS)
    p.add_argument("--exhaustive-checks", action="store_true")
    args = parser.parse_args()
    if args.operation == "plan":
        plan(args.directory, args.proof, args.run_id, args.release_id)
    elif args.operation == "retain":
        retain(
            json.loads(args.coverage.read_text()),
            json.loads(args.records.read_text()),
            args.system,
        )
    elif args.operation in ("check-roots", "verify"):
        verify(
            json.loads(args.coverage.read_text()),
            args.system,
            deep=args.operation == "verify" and args.exhaustive_checks,
        )
    else:
        reader(args.selection, args.component, deep=args.exhaustive_checks)


if __name__ == "__main__":
    main()
