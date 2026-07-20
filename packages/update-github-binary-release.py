#!/usr/bin/env python3

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path


SYSTEMS = ("aarch64-darwin", "x86_64-linux", "aarch64-linux")


def run(*args: str, cwd: Path | None = None) -> str:
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "command failed: " + " ".join(args))
    return result.stdout.strip()


def nix_eval(root: Path, attribute: str) -> str:
    return run(
        "nix",
        "eval",
        "--accept-flake-config",
        "--raw",
        f".#{attribute}",
        cwd=root,
    )


def fetch_release(repo: str, tag: str | None) -> dict:
    endpoint = (
        "releases/latest" if tag is None else f"releases/tags/{urllib.parse.quote(tag)}"
    )
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/{endpoint}",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "nix-update",
            **(
                {"Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}"}
                if os.environ.get("GITHUB_TOKEN")
                else {}
            ),
        },
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def sri_hash(digest: str) -> str:
    match = re.fullmatch(r"sha256:([0-9a-f]{64})", digest)
    if not match:
        raise RuntimeError(f"unsupported release asset digest: {digest!r}")
    return "sha256-" + base64.b64encode(bytes.fromhex(match.group(1))).decode()


def replace_once(text: str, old: str, new: str, description: str) -> str:
    if text.count(old) != 1:
        raise RuntimeError(f"expected exactly one {description} in the package file")
    return text.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) not in (3, 4):
        raise RuntimeError(f"usage: {sys.argv[0]} OWNER/REPO TAG_PREFIX [VERSION]")

    repo, tag_prefix = sys.argv[1:3]
    requested_version = sys.argv[3] if len(sys.argv) == 4 else None
    attribute = os.environ.get("UPDATE_NIX_ATTR_PATH", "")
    current_version = os.environ.get("UPDATE_NIX_OLD_VERSION", "")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", attribute) or not current_version:
        raise RuntimeError(
            "run this updater through nix-update --flake --use-update-script"
        )

    root = Path(run("git", "rev-parse", "--show-toplevel"))
    package_file = root / "packages" / f"{attribute}.nix"
    if not package_file.is_file():
        raise RuntimeError(f"package file not found: {package_file}")

    release = fetch_release(
        repo,
        f"{tag_prefix}{requested_version}" if requested_version is not None else None,
    )
    tag = release.get("tag_name", "")
    if not tag.startswith(tag_prefix):
        raise RuntimeError(f"release tag {tag!r} does not start with {tag_prefix!r}")
    version = tag.removeprefix(tag_prefix)
    if requested_version is not None and version != requested_version:
        raise RuntimeError(f"requested {requested_version}, GitHub returned {version}")

    release_assets = {}
    for asset in release.get("assets", []):
        name = asset.get("name")
        if name in release_assets:
            raise RuntimeError(f"duplicate release asset: {name}")
        release_assets[name] = asset

    replacements = []
    for system in SYSTEMS:
        source = f"packages.{system}.{attribute}.src"
        url = nix_eval(root, f"{source}.url")
        old_hash = nix_eval(root, f"{source}.outputHash")
        old_name = Path(urllib.parse.urlparse(url).path).name
        name = old_name.replace(current_version, version)
        asset = release_assets.get(name)
        if asset is None:
            raise RuntimeError(f"release asset not found: {name}")
        replacements.append((old_hash, sri_hash(asset.get("digest", "")), system))

    original = package_file.read_text()
    updated = replace_once(
        original,
        f'version = "{current_version}";',
        f'version = "{version}";',
        "version",
    )
    for old_hash, new_hash, system in replacements:
        updated = replace_once(updated, old_hash, new_hash, f"{system} hash")

    if updated == original:
        print(f"{attribute} is already up to date at {version}")
        return

    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", dir=package_file.parent, prefix=f".{package_file.name}.", delete=False
        ) as output:
            output.write(updated)
            output.flush()
            os.fsync(output.fileno())
            temporary = Path(output.name)
        temporary.chmod(package_file.stat().st_mode)
        os.replace(temporary, package_file)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)

    print(f"updated {attribute}: {current_version} -> {version}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit(f"update-github-binary-release: {error}") from error
