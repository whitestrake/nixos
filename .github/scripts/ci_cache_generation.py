#!/usr/bin/env python3
"""Immutable complete Release generations, authenticated through GitHub Actions."""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from ci_cache_image import (
    DRAFT_NAME,
    download_whole,
    file_sha256,
    gh_api,
    gh_download_whole,
    gh_upload,
    identity,
    is_sha256,
    positive,
    require,
    sha256,
    validate_identity,
    validate_manifest,
)

SCHEMA = "ci-cache-generation-v1"
PROMOTION_SCHEMA = "ci-cache-promotion-v1"
MANIFEST = "generation.json"
PREFIX = "ci-cache-v1-"
PUBLISHER = ".github/workflows/github-cache-maintenance.yml"
SOURCE_WORKFLOW = ".github/workflows/continuous-integration.yml"
READERS = (
    {
        "name": "Check x86_64-linux minimal",
        "component": "linux-seed-x86_64-linux",
        "system": "x86_64-linux",
        "runner": "ubuntu-24.04",
        "mode": "",
    },
    {
        "name": "Check x86_64-linux full",
        "component": "linux-full-x86_64-linux",
        "system": "x86_64-linux",
        "runner": "ubuntu-24.04",
        "mode": "",
    },
    {
        "name": "Check aarch64-linux full",
        "component": "linux-full-aarch64-linux",
        "system": "aarch64-linux",
        "runner": "ubuntu-24.04-arm",
        "mode": "",
    },
    {
        "name": "Check aarch64-darwin dmg",
        "component": "darwin-image-aarch64-darwin",
        "system": "aarch64-darwin",
        "runner": "macos-26",
        "mode": "hot",
    },
    {
        "name": "Check aarch64-darwin sparsebundle",
        "component": "darwin-maintenance-aarch64-darwin",
        "system": "aarch64-darwin",
        "runner": "macos-26",
        "mode": "maintenance",
    },
)
COMPONENTS = tuple(reader["component"] for reader in READERS)
GRACE = 24 * 60 * 60
AUTHORS = {"whitestrake[bot]", "github-actions[bot]"}


def owned(release):
    return re.fullmatch(r"ci-cache-v1-[0-9]+", release.get("tag_name", "")) is not None


def fingerprint(coverage):
    require(
        isinstance(coverage, dict) and set(coverage) == {"roots", "inputs", "tools"},
        "invalid coverage",
    )
    require(
        isinstance(coverage["roots"], list)
        and coverage["roots"]
        and all(isinstance(root, str) and root for root in coverage["roots"]),
        "missing roots",
    )
    require(
        all(isinstance(coverage[k], dict) and coverage[k] for k in ("inputs", "tools")),
        "missing inputs or tools",
    )
    canonical = {**coverage, "roots": sorted(set(coverage["roots"]))}
    return sha256(json.dumps(canonical, sort_keys=True, separators=(",", ":")).encode())


def validate_source(source):
    require(
        re.fullmatch(r"[0-9a-f]{40}", source.get("revision", ""))
        and positive(source.get("runId")),
        "invalid source identity",
    )
    proof = source.get("proof", {})
    require(
        re.fullmatch(
            r"/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+",
            proof.get("storePath", ""),
        )
        and is_sha256(proof.get("sha256")),
        "invalid proof identity",
    )


def validate_generation(generation):
    require(
        generation.get("schema") == SCHEMA and positive(generation.get("releaseId")),
        "invalid generation",
    )
    require(positive(generation.get("publisherRunId")), "invalid publisher run")
    validate_source(generation.get("source", {}))
    fingerprint(generation.get("coverage"))
    components = generation.get("components", {})
    require(
        set(components) == set(COMPONENTS),
        "generation must contain exactly five components",
    )
    for name, asset in components.items():
        validate_identity(asset)
        require(asset["name"] == name + ".json", "component manifest name mismatch")
    require(
        len({v["assetId"] for v in components.values()}) == len(COMPONENTS),
        "duplicate component assets",
    )


def check_run(repo, run_id, revision, workflow, production=False, successful=False):
    run = gh_api(repo, f"actions/runs/{run_id}")
    require(
        run.get("id") == run_id and run.get("head_sha") == revision,
        "run revision mismatch",
    )
    require(run.get("head_repository", {}).get("full_name") == repo, "foreign run")
    require(run.get("path") == workflow, "unexpected workflow")
    if production:
        require(
            run.get("head_branch") == "master"
            and run.get("event") in ("push", "workflow_run", "workflow_dispatch"),
            "untrusted production run",
        )
    if successful:
        require(
            run.get("conclusion") == "success" and run.get("status") == "completed",
            "source CI did not succeed",
        )
    return run


def trusted_generation(repo, generation, production):
    source = generation["source"]
    check_run(
        repo, generation["publisherRunId"], source["revision"], PUBLISHER, production
    )
    check_run(
        repo,
        source["runId"],
        source["revision"],
        SOURCE_WORKFLOW,
        production,
        successful=True,
    )


def verify_proof(source, production=False):
    validate_source(source)
    body = subprocess.run(
        [
            "nix",
            "store",
            "cat",
            "--store",
            "https://whitestrake.cachix.org",
            source["proof"]["storePath"],
        ],
        stdout=subprocess.PIPE,
        check=True,
        timeout=120,
    ).stdout
    require(
        len(body) <= 1024 * 1024 and sha256(body) == source["proof"]["sha256"],
        "proof digest mismatch",
    )
    canonical = subprocess.run(
        ["jq", "-ceS", "-f", str(Path(__file__).with_name("ci-build-proof.jq"))],
        input=body,
        stdout=subprocess.PIPE,
        check=True,
        timeout=30,
    ).stdout
    proof = json.loads(canonical)
    if production:
        pins = json.loads(
            subprocess.check_output(
                [
                    "bash",
                    "-euo",
                    "pipefail",
                    "-c",
                    'source "$1"; cachix_fetch_pins whitestrake',
                    "cachix-pins",
                    str(
                        Path(__file__).resolve().parents[2]
                        / "modules/deployment/scripts/cachix-pin-functions.sh"
                    ),
                ],
                timeout=60,
            )
        )
        matches = [pin for pin in pins if pin.get("name") == "successful-master-build"]
        require(
            len(matches) == 1
            and matches[0].get("lastRevision", {}).get("storePath")
            == source["proof"]["storePath"],
            "proof is not accepted master proof",
        )
    require(
        proof.get("revision") == source["revision"]
        and isinstance(proof.get("records"), list)
        and proof["records"],
        "proof revision or records mismatch",
    )


def asset_body(repo, release, pin, limit=64 * 1024 * 1024):
    matches = [a for a in release["assets"] if a.get("id") == pin["assetId"]]
    require(len(matches) == 1 and identity(matches[0]) == pin, "asset identity changed")
    body = (
        gh_download_whole(repo, matches[0], limit)
        if release.get("draft")
        else download_whole(matches[0], limit)
    )
    require(sha256(body) == pin["sha256"], "asset content digest mismatch")
    return body


def load_generation(repo, release_id=None, production=None):
    require(release_id is None or positive(release_id), "invalid pinned release ID")
    release = gh_api(
        repo, f"releases/{release_id}" if release_id else "releases/latest"
    )
    require(owned(release) and not release.get("draft"), "no complete owned generation")
    require(
        release_id is not None or not release.get("prerelease"),
        "latest is an unpromoted candidate",
    )
    if release_id is not None:
        require(release.get("id") == release_id, "release identity changed")
    require(
        release.get("author", {}).get("login") in AUTHORS,
        "unexpected release owner",
    )
    assets = [a for a in release["assets"] if a.get("name") == MANIFEST]
    require(len(assets) == 1, "missing generation manifest")
    pin = identity(assets[0])
    generation = json.loads(asset_body(repo, release, pin, 64 * 1024))
    validate_generation(generation)
    require(
        generation["releaseId"] == release["id"]
        and release.get("target_commitish") == generation["source"]["revision"],
        "generation release mismatch",
    )
    for component in generation["components"].values():
        require(
            any(
                identity(a) == component
                for a in release["assets"]
                if a.get("id") == component["assetId"]
            ),
            "missing component manifest",
        )
    trusted_generation(
        repo, generation, release_id is None if production is None else production
    )
    return generation, pin


def resolve(repo, output, release_id=None):
    # Never re-resolve latest for an already selected job, even if it has moved.
    output = Path(output)
    if output.exists():
        raise FileExistsError(output)
    generation, pin = load_generation(repo, release_id)
    selection = {
        "schema": "ci-cache-selection-v1",
        "repo": repo,
        "generation": generation,
        "manifest": pin,
        "production": release_id is None,
    }
    with output.open("x") as stream:
        json.dump(selection, stream, separators=(",", ":"))
    return selection


def read_selection(path, repo):
    # resolve() authenticates this job-local handoff before cached tooling runs.
    # Readers still verify downloaded manifests and bytes against its identities.
    selection = json.loads(Path(path).read_text())
    require(
        selection.get("schema") == "ci-cache-selection-v1"
        and selection.get("repo") == repo,
        "invalid selection",
    )
    validate_identity(selection["manifest"])
    require(
        type(selection.get("production")) is bool,
        "selection requires explicit trust mode",
    )
    validate_generation(selection["generation"])
    require(
        selection["manifest"]["name"] == MANIFEST, "invalid generation manifest name"
    )
    return selection


def publisher_context(repo, revision, production):
    require(
        os.environ.get("GITHUB_REPOSITORY") == repo,
        "publisher must run in its repository",
    )
    run_id = int(os.environ.get("GITHUB_RUN_ID", "0"))
    require(positive(run_id), "publisher requires Actions run context")
    check_run(repo, run_id, revision, PUBLISHER, production)
    if production:
        require(
            gh_api(repo, "commits/master")["sha"] == revision,
            "source is no longer current master",
        )
    return run_id


def upload(repo, release, path):
    require(
        not any(a["name"] == path.name for a in release["assets"]),
        "asset already exists",
    )
    gh_upload(repo, release["tag_name"], path)
    fresh = gh_api(repo, f"releases/{release['id']}")
    matches = [a for a in fresh["assets"] if a["name"] == path.name]
    require(len(matches) == 1, "uploaded asset missing")
    pin = identity(matches[0])
    require(
        pin["sha256"] == file_sha256(path) and pin["size"] == path.stat().st_size,
        "upload integrity mismatch",
    )
    release.update(fresh)
    return pin


def candidate(repo, release_id):
    release = gh_api(repo, f"releases/{release_id}")
    require(
        release.get("id") == release_id and owned(release) and release.get("draft"),
        "not an owned draft",
    )
    require(
        release.get("author", {}).get("login") in AUTHORS,
        "unexpected release owner",
    )
    assets = [a for a in release["assets"] if a["name"] == "candidate.json"]
    require(len(assets) == 1, "missing candidate identity")
    plan = json.loads(asset_body(repo, release, identity(assets[0]), 65536))
    require(plan["releaseId"] == release_id, "candidate identity mismatch")
    require(
        publisher_context(repo, plan["source"]["revision"], False)
        == plan["publisherRunId"],
        "candidate belongs to another publisher",
    )
    return release, plan


def begin(repo, source, coverage):
    validate_source(source)
    publisher = publisher_context(repo, source["revision"], False)
    plan = {
        "schema": SCHEMA,
        "releaseId": 1,
        "source": source,
        "publisherRunId": publisher,
        "coverage": coverage,
        "components": {},
    }
    trusted_generation(repo, plan, False)
    verify_proof(source)
    fingerprint(coverage)
    tag = (
        PREFIX
        + str(publisher)
        + str(int(os.environ.get("GITHUB_RUN_ATTEMPT", "1"))).zfill(3)
    )
    release = gh_api(
        repo,
        "releases",
        "POST",
        {
            "tag_name": tag,
            "target_commitish": source["revision"],
            "name": tag,
            "draft": True,
            "prerelease": False,
            "make_latest": "false",
            "body": json.dumps({"schema": PROMOTION_SCHEMA}, separators=(",", ":")),
        },
        token=os.environ["RELEASE_TOKEN"],
    )
    plan["releaseId"] = release["id"]
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "candidate.json"
        path.write_text(json.dumps(plan, separators=(",", ":")))
        upload(repo, release, path)
    return {"releaseId": release["id"], "tag": tag}


def upload_component(repo, release_id, component, directory):
    require(component in COMPONENTS, "unknown component")
    release, plan = candidate(repo, release_id)
    require(
        not any(a["name"] == component + ".json" for a in release["assets"]),
        "component already exists",
    )
    directory = Path(directory)
    manifest = json.loads((directory / DRAFT_NAME).read_text())
    validate_manifest(manifest, require_assets=False)
    coverage = manifest.get("coverage")
    fingerprint(coverage)
    require(
        set(coverage["roots"]) <= set(plan["coverage"]["roots"]),
        "component roots exceed generation coverage",
    )
    for field in ("inputs", "tools"):
        require(
            all(
                plan["coverage"][field].get(key) == value
                for key, value in coverage[field].items()
            ),
            "component coverage does not match generation",
        )
    if component == "darwin-image-aarch64-darwin":
        require(
            "hotPack" in manifest
            and manifest.get("filesystemGate", {}).get("imageSha256")
            == manifest["imageSha256"],
            "Darwin image needs exact-image gate and hot pack",
        )
    # Prefix names per component. Hard links avoid another multi-GB payload copy.
    with tempfile.TemporaryDirectory(dir=directory) as temporary:
        for item in manifest["shards"] + (
            [manifest["hotPack"]] if "hotPack" in manifest else []
        ):
            require(
                re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,149}", item["name"]),
                "invalid producer asset name",
            )
            source = directory / item["name"]
            require(
                source.is_file()
                and source.stat().st_size == item["size"]
                and file_sha256(source) == item["sha256"],
                "producer payload mismatch",
            )
            path = Path(temporary) / (component + "-" + item["name"])
            os.link(source, path)
            pin = upload(repo, release, path)
            item.update(pin)
        manifest["releaseId"] = release_id
        manifest["component"] = component
        validate_manifest(manifest)
        path = Path(temporary) / (component + ".json")
        path.write_text(json.dumps(manifest, separators=(",", ":")))
        return upload(repo, release, path)


def seal(repo, release_id):
    release, generation = candidate(repo, release_id)
    expected_coverage = fingerprint(generation["coverage"])
    actual_coverage = {"roots": [], "inputs": {}, "tools": {}}
    for component in COMPONENTS:
        matches = [a for a in release["assets"] if a["name"] == component + ".json"]
        require(len(matches) == 1, "missing component")
        pin = identity(matches[0])
        manifest = json.loads(asset_body(repo, release, pin))
        validate_manifest(manifest)
        coverage = manifest.get("coverage")
        fingerprint(coverage)
        require(
            set(coverage["roots"]) <= set(generation["coverage"]["roots"]),
            "component roots exceed generation coverage",
        )
        actual_coverage["roots"].extend(coverage["roots"])
        for field in ("inputs", "tools"):
            for key, value in coverage[field].items():
                require(
                    key in generation["coverage"][field]
                    and generation["coverage"][field][key] == value
                    and (
                        key not in actual_coverage[field]
                        or actual_coverage[field][key] == value
                    ),
                    "conflicting component coverage identity",
                )
                actual_coverage[field][key] = value
        require(
            manifest["releaseId"] == release_id
            and manifest.get("component") == component,
            "component identity mismatch",
        )
        for shard in manifest["shards"] + (
            [manifest["hotPack"]] if "hotPack" in manifest else []
        ):
            require(
                any(
                    identity(a)
                    == {k: shard[k] for k in ("assetId", "name", "size", "sha256")}
                    for a in release["assets"]
                    if a["id"] == shard["assetId"]
                ),
                "component payload missing",
            )
        generation["components"][component] = pin
    require(
        fingerprint(actual_coverage) == expected_coverage,
        "generation coverage is not the complete component union",
    )
    validate_generation(generation)
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / MANIFEST
        path.write_text(json.dumps(generation, separators=(",", ":")))
        require(path.stat().st_size <= 64 * 1024, "generation metadata too large")
        upload(repo, release, path)
    gh_api(
        repo,
        f"releases/{release_id}",
        "PATCH",
        {"draft": False, "prerelease": True, "make_latest": "false"},
    )
    load_generation(repo, release_id, production=False)
    return {"releaseId": release_id}


def latest_release(repo):
    try:
        return gh_api(repo, "releases/latest")
    except subprocess.CalledProcessError as error:
        if b"HTTP 404" in (error.stderr or b""):
            return None
        raise


def promotion_journal(release):
    body = release.get("body")
    if body in (None, ""):
        return {"schema": PROMOTION_SCHEMA}
    try:
        journal = json.loads(body)
    except (TypeError, json.JSONDecodeError) as error:
        raise ValueError("invalid promotion journal") from error
    require(
        isinstance(journal, dict)
        and journal.get("schema") == PROMOTION_SCHEMA
        and set(journal) <= {"schema", "promotionIntent", "promotion"},
        "invalid promotion journal",
    )
    return journal


def write_promotion_journal(repo, release, name, value):
    fresh = gh_api(repo, f"releases/{release['id']}")
    require(fresh.get("id") == release["id"], "release identity changed")
    journal = promotion_journal(fresh)
    require(
        name in ("promotionIntent", "promotion")
        and (name not in journal or journal[name] == value),
        "conflicting promotion journal",
    )
    journal[name] = value
    body = json.dumps(journal, separators=(",", ":"))
    observed = gh_api(repo, f"releases/{release['id']}", "PATCH", {"body": body})
    require(
        observed.get("id") == release["id"] and promotion_journal(observed) == journal,
        "promotion journal write was not observed",
    )
    release.update(observed)


def validate_promotion_intent(release, intent):
    require(
        isinstance(intent, dict)
        and set(intent) == {"releaseId", "previousId", "publisherRunId"}
        and intent.get("releaseId") == release.get("id")
        and positive(intent.get("publisherRunId"))
        and (intent.get("previousId") is None or positive(intent["previousId"])),
        "invalid promotion journal intent",
    )


def validate_promotion_receipt(release, record):
    require(
        isinstance(record, dict)
        and set(record)
        in (
            {
                "releaseId",
                "previousId",
                "publisherRunId",
                "intentSha256",
                "promotedAt",
            },
            {
                "releaseId",
                "previousId",
                "publisherRunId",
                "intentSha256",
                "promotedAt",
                "recoveredByRunId",
            },
        )
        and record.get("releaseId") == release.get("id")
        and positive(record.get("publisherRunId"))
        and positive(record.get("promotedAt"))
        and (record.get("previousId") is None or positive(record["previousId"]))
        and record.get("previousId") != release.get("id")
        and is_sha256(record.get("intentSha256"))
        and ("recoveredByRunId" not in record or positive(record["recoveredByRunId"])),
        "invalid promotion journal record",
    )


def promotion_record_present(release):
    matches = [
        asset
        for asset in release.get("assets", [])
        if asset.get("name") == "promotion.json"
    ]
    require(len(matches) <= 1, "duplicate promotion record")
    if matches:
        return True
    journal = promotion_journal(release)
    if "promotionIntent" in journal:
        validate_promotion_intent(release, journal["promotionIntent"])
    if "promotion" not in journal:
        return False
    record = journal["promotion"]
    validate_promotion_receipt(release, record)
    return True


def promotion_intent_present(release):
    matches = [
        asset
        for asset in release.get("assets", [])
        if asset.get("name") == "promotion-intent.json"
    ]
    require(len(matches) <= 1, "duplicate promotion intent")
    if matches:
        return True
    journal = promotion_journal(release)
    if "promotionIntent" not in journal:
        return False
    validate_promotion_intent(release, journal["promotionIntent"])
    return True


def promotion_intent(repo, release):
    matches = [
        asset
        for asset in release.get("assets", [])
        if asset.get("name") == "promotion-intent.json"
    ]
    require(len(matches) <= 1, "duplicate promotion intent")
    if matches:
        pin = identity(matches[0])
        intent = json.loads(asset_body(repo, release, pin, 65536))
    else:
        journal = promotion_journal(release)
        require("promotionIntent" in journal, "missing promotion intent")
        intent = journal["promotionIntent"]
        pin = {
            "sha256": sha256(
                json.dumps(intent, sort_keys=True, separators=(",", ":")).encode()
            )
        }
    validate_promotion_intent(release, intent)
    return intent, pin


def finish_promotion(repo, release, recovery_run=None):
    intent, pin = promotion_intent(repo, release)
    # Only a generation observed current can be completed. A delayed completion
    # starts grace later, never before its real promotion.
    require(
        latest_release(repo)["id"] == release["id"], "generation is no longer current"
    )
    record = {**intent, "intentSha256": pin["sha256"], "promotedAt": int(time.time())}
    if recovery_run:
        record["recoveredByRunId"] = recovery_run
    write_promotion_journal(repo, release, "promotion", record)
    return record


def promotion_record(repo, release, generation):
    matches = [
        asset
        for asset in release.get("assets", [])
        if asset.get("name") == "promotion.json"
    ]
    require(len(matches) <= 1, "duplicate promotion record")
    if matches:
        record = json.loads(asset_body(repo, release, identity(matches[0]), 65536))
    else:
        record = promotion_journal(release).get("promotion")
        require(isinstance(record, dict), "missing promotion record")
        validate_promotion_receipt(release, record)
    intent, pin = promotion_intent(repo, release)
    require(
        record.get("releaseId") == release["id"]
        and positive(record.get("promotedAt"))
        and record.get("previousId") != release["id"]
        and record.get("publisherRunId") == generation["publisherRunId"]
        and record.get("intentSha256") == pin["sha256"]
        and all(record.get(k) == v for k, v in intent.items()),
        "invalid promotion record",
    )
    return record


def promote(repo, release_id):
    generation, _ = load_generation(repo, release_id, production=True)
    run_id = publisher_context(repo, generation["source"]["revision"], True)
    require(
        run_id == generation["publisherRunId"], "only original publisher can promote"
    )
    verify_proof(generation["source"], production=True)
    release = gh_api(repo, f"releases/{generation['releaseId']}")
    latest = latest_release(repo)
    previous = None
    if latest and owned(latest):
        current, _ = load_generation(repo, latest["id"], production=True)
        if latest["id"] == release["id"]:
            if not promotion_record_present(latest):
                intent, _ = promotion_intent(repo, latest)
                require(
                    intent["publisherRunId"] == current["publisherRunId"],
                    "promotion publisher mismatch",
                )
                record = finish_promotion(repo, latest, recovery_run=run_id)
                promotion_record(repo, latest, current)
                return record
            return promotion_record(repo, latest, current)
        if not promotion_record_present(latest):
            finish_promotion(repo, latest, recovery_run=run_id)
        promotion_record(repo, latest, current)
        previous = latest["id"]
    require(release.get("prerelease"), "candidate is not a prerelease")
    require(not promotion_record_present(release), "promotion receipt already exists")
    intent = {
        "releaseId": release["id"],
        "previousId": previous,
        "publisherRunId": run_id,
    }
    if promotion_intent_present(release):
        existing, _ = promotion_intent(repo, release)
        require(existing == intent, "conflicting promotion intent")
    else:
        write_promotion_journal(repo, release, "promotionIntent", intent)
    publisher_context(repo, generation["source"]["revision"], True)
    observed = latest_release(repo)
    require(
        (observed["id"] if observed else None) == (latest["id"] if latest else None),
        "latest changed before promotion",
    )
    gh_api(
        repo,
        f"releases/{release['id']}",
        "PATCH",
        {"prerelease": False, "make_latest": "true"},
    )
    return finish_promotion(repo, release)


def retirement_plan(releases, current, now):
    # ponytail: frequent promotions retain extras; track retirement individually if space demands it.
    if now - current["promotedAt"] < GRACE:
        return []
    protected = {current["releaseId"], current["previousId"]}
    return sorted(
        release["id"]
        for release in releases
        if owned(release)
        and not release.get("draft")
        and release["id"] not in protected
        and promotion_record_present(release)
    )


def release_inventory(repo):
    releases = []
    for page in range(1, 101):
        batch = gh_api(repo, f"releases?per_page=100&page={page}")
        releases.extend(batch)
        if len(batch) < 100:
            return releases
    raise ValueError("release inventory exceeds bound")


def candidate_ready(release, run, repo, now):
    tag = re.fullmatch(r"ci-cache-v1-([0-9]+)([0-9]{3})", release.get("tag_name", ""))
    promoted = promotion_record_present(release)
    if not (
        tag
        and not promoted
        and (
            release.get("draft")
            or (release.get("prerelease") and run.get("head_branch") == "master")
        )
        and release.get("author", {}).get("login") in AUTHORS
    ):
        return False
    return (
        run.get("id") == int(tag[1])
        and run.get("run_attempt", 0) >= int(tag[2]) > 0
        and run.get("status") == "completed"
        and run.get("path") == PUBLISHER
        and run.get("head_repository", {}).get("full_name") == repo
        and run.get("head_sha") == release.get("target_commitish")
        and now
        - max(
            datetime.fromisoformat(value).timestamp()
            for value in (release["updated_at"], run["updated_at"])
        )
        >= GRACE
    )


def tag_ref(repo, tag):
    try:
        return gh_api(repo, f"git/ref/tags/{tag}")
    except subprocess.CalledProcessError as error:
        if b"HTTP 404" not in (error.stderr or b""):
            raise
        return None


def delete_release_and_tag(repo, release, expected_tag):
    gh_api(repo, f"releases/{release['id']}", "DELETE")
    name = release["tag_name"]
    if expected_tag is None:
        require(tag_ref(repo, name) is None, f"orphan tag {name} appeared")
        return
    last_error = None
    for _ in range(3):
        try:
            fresh = tag_ref(repo, name)
            if fresh is None:
                return
            require(
                fresh == expected_tag,
                f"orphan tag {name} changed after release deletion",
            )
            gh_api(repo, f"git/refs/tags/{name}", "DELETE")
            return
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            last_error = error
    raise ValueError(
        f"release {release['id']} deleted but orphan tag {name} could not be deleted"
    ) from last_error


def prune_candidates(repo, execute=False):
    publisher = publisher_context(repo, os.environ["GITHUB_SHA"], False)
    removed = []
    for release in release_inventory(repo):
        tag = re.fullmatch(r"ci-cache-v1-([0-9]+)([0-9]{3})", release["tag_name"])
        if (
            not tag
            or not (release["draft"] or release["prerelease"])
            or int(tag[1]) == publisher
        ):
            continue
        try:
            # Read the latest attempt: an active rerun protects every draft of that run.
            run = gh_api(repo, f"actions/runs/{int(tag[1])}")
            release = gh_api(repo, f"releases/{release['id']}")
            if not candidate_ready(release, run, repo, time.time()):
                continue
            candidates = [a for a in release["assets"] if a["name"] == "candidate.json"]
            require(
                release["draft"] or len(candidates) == 1, "missing candidate identity"
            )
            if candidates:
                require(len(candidates) == 1, "duplicate candidate identity")
                candidate = json.loads(
                    asset_body(repo, release, identity(candidates[0]), 65536)
                )
                require(
                    candidate["releaseId"] == release["id"]
                    and candidate["publisherRunId"] == run["id"]
                    and candidate["source"]["revision"] == run["head_sha"],
                    "candidate identity mismatch",
                )
        except (ValueError, KeyError, subprocess.CalledProcessError) as error:
            print(
                f"::warning ::Leaving unverifiable cache candidate {release['id']}: {type(error).__name__}"
            )
            continue
        if execute:
            ref = tag_ref(repo, release["tag_name"])
            if ref is not None:
                require(
                    ref["object"]["type"] == "commit"
                    and ref["object"]["sha"] == run["head_sha"],
                    "candidate tag target changed",
                )
            fresh = gh_api(repo, f"releases/{release['id']}")
            require(
                not promotion_record_present(fresh)
                and (fresh["draft"] or fresh["prerelease"]),
                "candidate was promoted during cleanup",
            )
            require(
                tag_ref(repo, release["tag_name"]) == ref,
                "candidate tag changed before cleanup",
            )
            delete_release_and_tag(repo, fresh, ref)
        removed.append(release["id"])
    return {"candidateIds": removed, "executed": execute}


def prune(repo, source, execute=False):
    validate_source(source)
    run_id = publisher_context(repo, source["revision"], True)
    check_run(
        repo,
        source["runId"],
        source["revision"],
        SOURCE_WORKFLOW,
        production=True,
        successful=True,
    )
    verify_proof(source, production=True)
    latest = gh_api(repo, "releases/latest")
    generation, _ = load_generation(repo, latest["id"], production=True)
    if not promotion_record_present(latest):
        intent, _ = promotion_intent(repo, latest)
        require(
            intent["publisherRunId"] == generation["publisherRunId"],
            "promotion publisher mismatch",
        )
        if not execute:
            return {"releaseIds": [], "executed": False}
        finish_promotion(repo, latest, recovery_run=run_id)
    current = promotion_record(repo, latest, generation)
    releases = release_inventory(repo)
    planned = retirement_plan(releases, current, int(time.time()))
    tag_targets = {}
    for release_id in planned:
        retired, _ = load_generation(repo, release_id, production=True)
        release = next(r for r in releases if r["id"] == release_id)
        record = promotion_record(repo, release, retired)
        require(record["promotedAt"] <= current["promotedAt"], "newer promotion found")
        tag = tag_ref(repo, release["tag_name"])
        require(
            tag is None
            or (
                tag.get("ref") == "refs/tags/" + release["tag_name"]
                and tag.get("object", {}).get("type") == "commit"
                and tag["object"]["sha"] == retired["source"]["revision"]
            ),
            "tag target does not match generation",
        )
        tag_targets[release_id] = tag
    if execute:
        for release_id in planned:
            require(
                gh_api(repo, "releases/latest")["id"] == latest["id"],
                "latest changed during pruning",
            )
            release = next(r for r in releases if r["id"] == release_id)
            require(
                tag_ref(repo, release["tag_name"]) == tag_targets[release_id],
                "tag changed before retirement",
            )
            delete_release_and_tag(repo, release, tag_targets[release_id])
    return {"releaseIds": planned, "executed": execute}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in (
        "resolve",
        "begin",
        "upload-component",
        "seal",
        "promote",
        "prune",
        "prune-candidates",
    ):
        command = commands.add_parser(name)
        command.add_argument("--repo", required=True)
        if name == "resolve":
            command.add_argument("--output", required=True, type=Path)
            command.add_argument("--release-id", type=int)
        elif name == "begin":
            for field in ("source", "coverage"):
                command.add_argument("--" + field, required=True, type=Path)
        elif name in ("upload-component", "seal", "promote"):
            command.add_argument("--release-id", required=True, type=int)
            if name == "upload-component":
                command.add_argument("--component", required=True, choices=COMPONENTS)
                command.add_argument("--directory", required=True, type=Path)
        else:
            if name == "prune":
                command.add_argument("--source", required=True, type=Path)
            command.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    if args.command == "resolve":
        result = resolve(args.repo, args.output, args.release_id)
    elif args.command == "begin":
        result = begin(
            args.repo,
            json.loads(args.source.read_text()),
            json.loads(args.coverage.read_text()),
        )
    elif args.command == "upload-component":
        result = upload_component(
            args.repo, args.release_id, args.component, args.directory
        )
    elif args.command == "seal":
        result = seal(args.repo, args.release_id)
    elif args.command == "promote":
        result = promote(args.repo, args.release_id)
    elif args.command == "prune-candidates":
        result = prune_candidates(args.repo, args.execute)
    else:
        result = prune(args.repo, json.loads(args.source.read_text()), args.execute)
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
