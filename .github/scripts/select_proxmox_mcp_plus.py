#!/usr/bin/env python3
"""Select the newest PyPI release compatible with the evaluated Nix package."""

import argparse
import hashlib
import json
import sys
import urllib.request
from email.parser import BytesParser
from email.policy import compat32
from pathlib import Path

from packaging.markers import default_environment
from packaging.requirements import Requirement
from packaging.specifiers import SpecifierSet
from packaging.utils import canonicalize_name
from packaging.version import Version


PROJECT = "proxmox-mcp-plus"
PYPI = f"https://pypi.org/pypi/{PROJECT}/json"


def get(url):
    with urllib.request.urlopen(url, timeout=20) as response:
        return response.read()


def release_metadata(files):
    wheels = [
        file
        for file in files
        if file["packagetype"] == "bdist_wheel"
        and file["filename"].endswith("-py3-none-any.whl")
        and not file["yanked"]
    ]
    sources = [
        file for file in files if file["packagetype"] == "sdist" and not file["yanked"]
    ]
    if not wheels or not sources:
        raise ValueError(
            "release has no non-yanked universal wheel and source distribution"
        )
    wheel = wheels[0]
    digest = wheel.get("core-metadata")
    if not isinstance(digest, dict) or not digest.get("sha256"):
        raise ValueError("wheel has no published core metadata digest")
    raw = get(wheel["url"] + ".metadata")
    if hashlib.sha256(raw).hexdigest() != digest["sha256"]:
        raise ValueError("wheel core metadata digest mismatch")
    metadata = BytesParser(policy=compat32).parsebytes(raw)
    if canonicalize_name(metadata["Name"] or "") != PROJECT or not metadata["Version"]:
        raise ValueError("wheel core metadata is missing its project name or version")
    return metadata


def environment(system, python):
    arch, os = system.split("-", 1)
    env = default_environment()
    env.update(
        python_version=".".join(python.split(".")[:2]),
        python_full_version=python,
        implementation_name="cpython",
        implementation_version=python,
        platform_python_implementation="CPython",
        sys_platform="darwin" if os == "darwin" else "linux",
        platform_system="Darwin" if os == "darwin" else "Linux",
        os_name="posix",
        platform_machine={
            "x86_64": "x86_64",
            "aarch64": "arm64" if os == "darwin" else "aarch64",
        }[arch],
        extra="",
    )
    return env


def assess(metadata, contexts):
    requirements = [
        Requirement(value) for value in metadata.get_all("Requires-Dist", [])
    ]
    python_range = SpecifierSet(metadata.get("Requires-Python", ""))
    incompatible = []
    undeclared = []
    for system, context in contexts.items():
        python = context["python"]
        if not python_range.contains(python):
            incompatible.append(f"{system}: Python {python} outside {python_range}")
        declared = {
            canonicalize_name(dep["name"]): dep["version"]
            for dep in context["dependencies"]
        }
        relaxed = {canonicalize_name(name) for name in context["relax"]}
        removed = {canonicalize_name(name) for name in context["remove"]}
        marker_env = environment(system, python)
        for requirement in requirements:
            name = canonicalize_name(requirement.name)
            if name in removed:
                continue
            if requirement.marker and any(
                field in str(requirement.marker)
                for field in ("platform_release", "platform_version")
            ):
                raise ValueError(f"cannot evaluate target kernel marker: {requirement}")
            if requirement.marker and not requirement.marker.evaluate(marker_env):
                continue
            if name not in declared:
                undeclared.append(f"{system}: {requirement}")
            elif name not in relaxed and not requirement.specifier.contains(
                declared[name]
            ):
                incompatible.append(
                    f"{system}: {name} {declared[name]} outside {requirement.specifier}"
                )
    return incompatible, undeclared


def select(index, contexts, metadata_for=release_metadata):
    versions = {context["version"] for context in contexts.values()}
    if len(versions) != 1:
        raise ValueError("evaluated package versions differ across systems")
    current = Version(versions.pop())
    candidates = sorted(
        (
            (Version(version), files)
            for version, files in index["releases"].items()
            if Version(version) > current and not Version(version).is_prerelease
        ),
        reverse=True,
    )
    for version, files in candidates:
        if not any(not file["yanked"] for file in files):
            continue
        metadata = metadata_for(files)
        if Version(metadata["Version"]) != version:
            raise ValueError(f"{version}: wheel metadata version mismatch")
        incompatible, undeclared = assess(metadata, contexts)
        for issue in incompatible:
            print(f"{version}: incompatible {issue}", file=sys.stderr)
        for issue in undeclared:
            print(f"{version}: undeclared {issue}", file=sys.stderr)
        if not incompatible:
            return str(version)
    return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("context", type=Path)
    args = parser.parse_args()
    contexts = json.loads(args.context.read_text())
    version = select(json.loads(get(PYPI)), contexts)
    if version:
        print(version)
    else:
        print("No compatible newer release", file=sys.stderr)


if __name__ == "__main__":
    main()
