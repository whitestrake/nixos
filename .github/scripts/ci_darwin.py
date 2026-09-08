#!/usr/bin/env python3
"""Darwin Release store lifecycle. Run with host Python, never a /nix interpreter."""

import argparse
import http.client
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import urllib.error

import ci_cache_image as image
from ci_cache_generation import read_selection
from ci_cache_workflow import verify

IMAGE = "darwin-image-aarch64-darwin"
MAINTENANCE = "darwin-maintenance-aarch64-darwin"
SCRIPTS = Path(__file__).resolve().parent
ROOTS = Path("/nix/var/nix/gcroots/github-ci/aarch64-darwin")


class CacheRestoreError(RuntimeError):
    pass


def command(*args, **kwargs):
    argv = [str(arg) for arg in args]
    timeout = kwargs.pop("timeout", 600)
    data = kwargs.pop("input", None)
    if data is not None:
        kwargs["stdin"] = subprocess.PIPE
    if kwargs.pop("capture_output", False):
        kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    with subprocess.Popen(argv, start_new_session=True, **kwargs) as process:
        try:
            stdout, stderr = process.communicate(data, timeout=timeout)
        except BaseException:
            stop_group(process.pid, process)
            raise
        result = subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
        result.check_returncode()
        return result


def write_json(path, value):
    path.write_text(json.dumps(value, separators=(",", ":")) + "\n")


def group_signal(pid, signum):
    try:
        os.killpg(pid, signum)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        members = subprocess.run(
            ["ps", "-axo", "pgid=,stat="], capture_output=True, text=True, check=True
        )
        if not any(
            line.split()[0] == str(pid) and not line.split()[1].startswith("Z")
            for line in members.stdout.splitlines()
            if len(line.split()) >= 2
        ):
            return False
        raise


def stop_group(pid, process=None):
    if not pid or not group_signal(pid, signal.SIGTERM):
        return
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if process is not None:
            process.poll()
        else:
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass
        if not group_signal(pid, 0):
            return
        time.sleep(0.05)
    group_signal(pid, signal.SIGKILL)
    if process is not None:
        process.wait(timeout=3)
    else:
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    deadline = time.monotonic() + 3
    while group_signal(pid, 0) and time.monotonic() < deadline:
        time.sleep(0.05)
    image.require(not group_signal(pid, 0), "owned process group survived cleanup")


def helper_fault(pid, marker):
    if marker.exists() and marker.read_text().strip() == "cache-backing-failure":
        return "backing-failure"
    if pid:
        result = subprocess.run(
            ["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True
        )
        status = result.stdout.strip()
        if not status or status.startswith("Z"):
            return "helper-exited"
        if status.startswith("T"):
            return "helper-stopped"
    return None


def supervise(argv, directory, helper_pid=None, marker=None):
    marker = marker or directory / "backing-failure"
    env = {**os.environ, "CI_DARWIN_ATTEMPT_DIR": str(directory)}
    for name in ("GITHUB_OUTPUT", "GITHUB_ENV", "GITHUB_STATE"):
        if name in env:
            env[name] = str(directory / name.lower())
    process = subprocess.Popen(argv, env=env, start_new_session=True)
    reason = None
    previous = {}

    def interrupt(signum, _frame):
        # Let nested NFB supervisors reap their separate owned sessions first.
        group_signal(process.pid, signum)
        raise KeyboardInterrupt

    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous[signum] = signal.signal(signum, interrupt)
        while process.poll() is None:
            reason = helper_fault(helper_pid, marker)
            if reason:
                stop_group(process.pid, process)
                break
            time.sleep(0.1)
        status = process.wait()
        reason = reason or helper_fault(helper_pid, marker)
        # A successful command still cannot select results from failed backing.
        return (status or 1, reason) if reason else (status, None)
    except KeyboardInterrupt:
        stop_group(process.pid, process)
        process.wait()
        return 130, None
    finally:
        stop_group(process.pid, process)
        process.wait()
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def state_root(path):
    path = Path(path).resolve()
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve()
    image.require(
        path != temporary and path.is_relative_to(temporary),
        "state must be beneath RUNNER_TEMP",
    )
    return path


def safe_extract(archive, destination):
    destination.mkdir(mode=0o700)
    seen = set()

    def confined(entry, target):
        path = Path(entry.name)
        image.require(
            not path.is_absolute()
            and ".." not in path.parts
            and path.parts
            and path.parts[0] == "nix-root.sparsebundle",
            "unsafe bundle archive path",
        )
        image.require(entry.isdir() or entry.isfile(), "unsafe bundle archive entry")
        image.require(path not in seen, "duplicate bundle archive entry")
        seen.add(path)
        return tarfile.data_filter(entry, target)

    with tarfile.open(archive, mode="r|zst", bufsize=1024 * 1024) as stream:
        stream.extractall(destination, filter=confined)
    bundle = destination / "nix-root.sparsebundle"
    image.require(
        (bundle / "Info.plist").is_file()
        and (bundle / "token").is_file()
        and (bundle / "bands").is_dir()
        and any((bundle / "bands").iterdir()),
        "incomplete sparsebundle",
    )
    with (bundle / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    image.require(
        info.get("diskimage-bundle-type") == "com.apple.diskimage.sparsebundle"
        and type(info.get("size")) is int
        and info["size"] > 0,
        "invalid sparsebundle metadata",
    )
    return bundle


def native_mountpoint():
    synthetic = Path("/etc/synthetic.conf")
    lines = synthetic.read_text().splitlines() if synthetic.exists() else []
    image.require(
        not any(
            line.split()[0] == "nix" and line != "nix" for line in lines if line.split()
        ),
        "conflicting synthetic nix entry",
    )
    if "nix" not in lines:
        command(
            "sudo",
            "tee",
            "-a",
            synthetic,
            input="nix\n",
            text=True,
            stdout=subprocess.DEVNULL,
        )
    utility = "/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util"
    result = subprocess.run(
        ["sudo", utility, "-B"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    if result.returncode:
        subprocess.run(
            ["sudo", utility, "-t"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    image.require(
        Path("/nix").is_dir() and not Path("/nix").is_symlink(),
        "missing native /nix mountpoint",
    )
    image.require(
        not any(Path("/nix").iterdir()), "/nix must be empty before attachment"
    )


def start_helper(root, argv, profile=None):
    reader = root / "reader"
    ready = reader / "ready.txt"
    log = root / "helper.log"
    with log.open("wb") as stream:
        command_line = [
            sys.executable,
            str(SCRIPTS / "ci_cache_image.py"),
            *map(str, argv),
            "--directory",
            str(reader),
            "--ready",
            str(ready),
        ]
        if profile:
            command_line += ["--profile", str(profile)]
        process = subprocess.Popen(
            command_line,
            stdout=stream,
            stderr=stream,
            start_new_session=True,
        )
    write_json(root / "helper.json", {"pid": process.pid})
    deadline = time.monotonic() + 600
    while not ready.exists():
        fault = helper_fault(process.pid, reader / "backing-failure")
        if fault or time.monotonic() >= deadline:
            stop_group(process.pid, process)
            process.wait()
            raise CacheRestoreError(fault or "helper-start-timeout")
        time.sleep(0.1)
    return ready.read_text().strip()


def helper_pid(root):
    path = root / "helper.json"
    return json.loads(path.read_text())["pid"] if path.exists() else None


def cleanup(root):
    # Refuse to detach while any unexpected process still has store files open.
    mount = root / "mounted"
    if mount.exists():
        # ReportCrash can retain store files briefly after owned children exit.
        deadline = time.monotonic() + 10
        while True:
            users = subprocess.run(
                ["sudo", "lsof", "-t", "+f", "--", "/nix"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if (
                users.returncode not in (0, 1)
                or not users.stdout.strip()
                or time.monotonic() >= deadline
            ):
                break
            time.sleep(0.2)
        if users.returncode not in (0, 1) or users.stdout.strip():
            subprocess.run(["sudo", "lsof", "+f", "--", "/nix"], timeout=5)
        image.require(
            users.returncode in (0, 1) and not users.stdout.strip(),
            "store users remain; refusing detach",
        )
    if mount.exists():
        mounted = subprocess.run(
            ["mount"], capture_output=True, text=True, check=True
        ).stdout
        if " on /nix (" in mounted:
            command("sudo", "hdiutil", "detach", "/nix", timeout=120)
        mount.unlink()
    # Native unmount may still read the HTTP base image beneath the shadow.
    stop_group(helper_pid(root))
    for name in ("reader", "restore", "bundle", "image.shadow", "helper.json"):
        path = root / name
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()


def attach(root, source, shadow=False):
    native_mountpoint()
    # Mark before attach so a partial successful native attachment is owned.
    (root / "mounted").touch()
    args = [
        "sudo",
        "hdiutil",
        "attach",
        source,
        "-mountpoint",
        "/nix",
        "-nobrowse",
        "-noautoopen",
        "-owners",
        "on",
    ]
    if shadow:
        args += ["-shadow", root / "image.shadow", "-noautofsck"]
    command(*args)
    command("sudo", "chown", os.environ["USER"], "/nix")
    Path("/nix").chmod(Path("/nix").stat().st_mode | 0o700)


def mount(root, mode, repo):
    write_json(root / "mode.json", {"mode": mode, "repo": repo})
    if mode == "cold":
        directory = root / "bundle"
        directory.mkdir()
        bundle = directory / "nix-root.sparsebundle"
        command(
            "hdiutil",
            "create",
            "-size",
            "32g",
            "-type",
            "SPARSEBUNDLE",
            "-fs",
            "Case-sensitive Journaled HFS+",
            "-volname",
            "NixStore",
            bundle,
        )
        attach(root, bundle)
        return
    selection = read_selection(root / "selection.json", repo)
    component = MAINTENANCE if mode == "maintenance" else IMAGE
    pin = selection["generation"]["components"][component]
    if mode == "hot":
        source = start_helper(
            root,
            [
                "serve",
                "--repo",
                repo,
                "--selection",
                root / "selection.json",
                "--component",
                IMAGE,
            ],
        )
    else:
        try:
            image.eager(
                repo, selection["generation"]["releaseId"], pin, root / "restore"
            )
            source = root / "restore/image.dmg"
            if mode == "maintenance":
                source = safe_extract(source, root / "bundle")
        except (
            ValueError,
            urllib.error.URLError,
            http.client.HTTPException,
            tarfile.TarError,
        ) as error:
            raise CacheRestoreError("payload-restore-failure") from error
    attach(root, source, shadow=mode in ("hot", "eager"))
    print(json.dumps({"mode": mode, "releaseId": selection["generation"]["releaseId"]}))


def recovery_ready():
    image.require(
        not Path("/nix/var/nix/daemon-socket/socket").exists(),
        "recovery requires single-user Nix",
    )
    result = subprocess.run(["pgrep", "-x", "nix-daemon"], stdout=subprocess.DEVNULL)
    image.require(result.returncode == 1, "unexpected Nix daemon")


def recover_setup(root):
    settings = json.loads((root / "mode.json").read_text())
    if settings["mode"] != "hot":
        return {"recovered": False}
    reason = helper_fault(helper_pid(root), root / "reader/backing-failure")
    if not reason:
        return {"recovered": False}
    cleanup(root)
    mount(root, "maintenance", settings["repo"])
    # The ordinary installer/Cachix actions run before recovery_ready in setup.
    return {"recovered": True, "cacheFault": reason}


def run(root, argv):
    settings = json.loads((root / "mode.json").read_text())
    hot = settings["mode"] == "hot"
    for number in (1, 2):
        directory = root / f"attempt-{number}"
        directory.mkdir(mode=0o700)
        started = time.monotonic()
        status, reason = supervise(
            argv,
            directory,
            helper_pid(root) if hot and number == 1 else None,
            root / "reader/backing-failure",
        )
        print(
            json.dumps(
                {
                    "attempt": number,
                    "status": status,
                    "cacheFault": reason,
                    "durationSeconds": round(time.monotonic() - started, 3),
                }
            ),
            flush=True,
        )
        if reason and number == 1:
            image.require(hot, "recovery is only supported for the hot reader")
            shutil.rmtree(directory)
            cleanup(root)
            mount(root, "maintenance", settings["repo"])
            recovery_ready()
            continue

        # Only a confirmed discarded cache attempt suppresses Checks API output.
        journal = directory / "checks.json"
        if journal.exists():
            command(
                sys.executable,
                SCRIPTS / "nix_fast_build.py",
                "--replay-checks",
                journal,
            )
        if status == 0 and reason is None:
            directory.rename(root / "selected")
            return 0
        return status or 1
    raise RuntimeError("unreachable recovery state")


def filesystem_gate(path):
    before = image.file_sha256(path)
    command("hdiutil", "verify", path)
    result = command(
        "hdiutil",
        "attach",
        path,
        "-readonly",
        "-nomount",
        "-noautofsck",
        "-plist",
        capture_output=True,
    )
    entities = plistlib.loads(result.stdout)["system-entities"]
    whole = next(entry["dev-entry"] for entry in entities if entry.get("dev-entry"))
    try:
        devices = [
            entry["dev-entry"]
            for entry in entities
            if entry.get("content-hint") == "Apple_HFS"
        ]
        image.require(len(devices) == 1, "expected exactly one HFS filesystem")
        checked = command(
            "sudo",
            "/sbin/fsck_hfs",
            "-fn",
            devices[0],
            capture_output=True,
            text=True,
            timeout=900,
        )
        image.require(
            "appears to be OK" in checked.stdout,
            "filesystem check did not confirm healthy HFS",
        )
    finally:
        command("hdiutil", "detach", whole, timeout=120)
    after = image.file_sha256(path)
    image.require(before == after, "filesystem validation changed image")
    return {
        "imageSha256": before,
        "imageSha256Before": before,
        "imageSha256After": after,
        "fsck": "fsck_hfs -fn",
        "fsckStatus": 0,
    }


def validate_hot(exported, manifest, hot, directory):
    # A fresh BlockStore authenticates every hot block against this exact image.
    store = image.BlockStore(
        manifest,
        directory,
        local_image=exported,
    )
    image.import_hot_pack(hot, store)


def produce(root, output, coverage, argv, deep=False):
    settings = json.loads((root / "mode.json").read_text())
    image.require(
        settings["mode"] in ("cold", "maintenance"),
        "producer requires writable sparsebundle",
    )
    bundle = root / "bundle/nix-root.sparsebundle"
    image.require(bundle.is_dir(), "missing producer sparsebundle")
    for tool in ("gtar", "zstd"):
        executable = shutil.which(tool)
        image.require(
            executable and not Path(executable).resolve().is_relative_to("/nix"),
            f"{tool} must be host-native outside /nix",
        )
    verify(coverage, "aarch64-darwin", deep=deep)
    cachix = Path(shutil.which("cachix") or "").resolve()
    image.require(
        str(cachix).startswith("/nix/store/") and cachix.name == "cachix",
        "ordinary Cachix must be installed",
    )
    closure = Path("/nix/store") / cachix.parts[3]
    command(
        "nix-store",
        "--add-root",
        ROOTS / "cachix",
        "--indirect",
        "--realise",
        closure,
        stdout=subprocess.DEVNULL,
    )
    command("nix", "store", "gc")
    command("sync")
    command("sudo", "hdiutil", "detach", "/nix", timeout=120)
    (root / "mounted").unlink()
    command("hdiutil", "compact", bundle, timeout=600)
    output.mkdir()
    archive = output / "nix-root.sparsebundle.tar.zst"
    command(
        "gtar",
        "--posix",
        "--sparse",
        "--use-compress-program=zstd",
        "-cf",
        archive,
        "-C",
        bundle.parent,
        bundle.name,
        env={**os.environ, "COPYFILE_DISABLE": "1"},
        timeout=1800,
    )
    exported = output / "nix-root.dmg"
    command(
        "hdiutil", "convert", bundle, "-format", "ULFO", "-o", exported, timeout=1800
    )
    gate = filesystem_gate(exported)
    packed = output / IMAGE
    image.pack_image(exported, packed, coverage=coverage, filesystem_gate=gate)
    manifest_path = packed / "draft-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    profile = output / "profile"
    profile.mkdir()
    block_profile = output / "profile.blocks"
    try:
        source = start_helper(
            profile,
            ["serve-local", "--image", exported, "--manifest", manifest_path],
            profile=block_profile,
        )
        attach(profile, source, shadow=True)
        verify(coverage, "aarch64-darwin")
        attempt = profile / "work"
        attempt.mkdir()
        for workload in ([str(ROOTS / "cachix/bin/cachix"), "--version"], argv):
            status, fault = supervise(
                workload,
                attempt,
                helper_pid(profile),
                profile / "reader/backing-failure",
            )
            image.require(
                status == 0 and fault is None, "exact-image profile workload failed"
            )
    finally:
        cleanup(profile)
    hot = packed / "hot.zip"
    image.pack_hot(exported, manifest_path, block_profile, hot)
    manifest["hotPack"] = {
        "name": hot.name,
        "size": hot.stat().st_size,
        "sha256": image.file_sha256(hot),
    }
    write_json(manifest_path, manifest)
    validate_hot(exported, manifest, hot, output / "hot-validation")
    image.require(
        image.file_sha256(exported) == gate["imageSha256"],
        "profile changed immutable image",
    )
    maintenance = output / MAINTENANCE
    image.pack_image(archive, maintenance, coverage=coverage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "operation",
        choices=("mount", "run", "cleanup", "produce", "recover-setup", "ready"),
    )
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument(
        "--mode", choices=("hot", "eager", "maintenance", "cold"), default="hot"
    )
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--selection", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--coverage", type=Path)
    parser.add_argument("--exhaustive-checks", action="store_true")
    arguments = sys.argv[1:]
    boundary = arguments.index("--") if "--" in arguments else len(arguments)
    argv = arguments[boundary + 1 :]
    args = parser.parse_args(arguments[:boundary])
    image.require(
        sys.platform == "darwin"
        and not Path(sys.executable).resolve().is_relative_to("/nix"),
        "use host-native Darwin Python outside /nix",
    )
    root = state_root(args.state)
    if args.operation == "mount":
        root.mkdir(mode=0o700)
        if args.mode != "cold":
            image.require(args.selection is not None, "frozen selection required")
            read_selection(args.selection, args.repo)
            shutil.copyfile(args.selection, root / "selection.json")
        try:
            mount(root, args.mode, args.repo)
        except Exception as error:
            fault = (
                helper_fault(helper_pid(root), root / "reader/backing-failure")
                if args.mode == "hot"
                else None
            )
            if not fault and isinstance(error, CacheRestoreError):
                fault = str(error)
            if not fault:
                raise
            cleanup(root)
            print(json.dumps({"fallback": fault, "phase": "mount"}))
            mount(
                root, "cold" if args.mode == "maintenance" else "maintenance", args.repo
            )
    elif args.operation == "recover-setup":
        result = recover_setup(root)
        print(json.dumps(result))
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"recovered={str(result['recovered']).lower()}\n")
        if not result["recovered"]:
            image.require(
                os.environ["INSTALL_OUTCOME"] == "success", "genuine Nix setup failure"
            )
            if os.environ["CONFIGURE_CACHIX"] == "true":
                image.require(
                    os.environ["CACHIX_OUTCOME"] == "success",
                    "genuine Cachix setup failure",
                )
    elif args.operation == "ready":
        recovery_ready()
    elif args.operation == "cleanup":
        cleanup(root)
    elif args.operation == "run":
        image.require(bool(argv), "build command required")
        return run(root, argv)
    else:
        image.require(
            bool(argv) and args.coverage and args.output,
            "producer coverage, output and validation command required",
        )
        produce(
            root,
            state_root(args.output),
            json.loads(args.coverage.read_text()),
            argv,
            args.exhaustive_checks,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
