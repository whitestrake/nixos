#!/usr/bin/env bash
set -euo pipefail

variant="${GATE4_VARIANT:?GATE4_VARIANT must be set}"
phase="${GATE4_PHASE:?GATE4_PHASE must be set}"
image="${GATE4_IMAGE_PATH:?GATE4_IMAGE_PATH must be set}"
fixture_dir="${RUNNER_TEMP:?RUNNER_TEMP must be set}/gate4-fixture"
work_dir="$(dirname "$image")"
trial="${work_dir##*/}"
evidence="${work_dir}/evidence.jsonl"
phase_started_ns="$(python3 -c 'import time; print(time.time_ns())')"

mkdir -p "$work_dir"
touch "$evidence"

case "$variant" in
  0-udsb-jhfsx)
    container=udsb
    expected_filesystem='Case-sensitive Journaled HFS+'
    expected_journal=true
    ;;
  1-udsb-hfsx)
    container=udsb
    expected_filesystem='Case-sensitive HFS+'
    expected_journal=false
    ;;
  2-udsb-apfsx)
    container=udsb
    expected_filesystem=APFS
    expected_journal=na
    ;;
  3-asif-apfsx)
    container=asif
    expected_filesystem=APFS
    expected_journal=na
    ;;
  *)
    echo "::error ::unsupported Gate 4 candidate: $variant"
    exit 2
    ;;
esac

case "$phase" in
  prepare | verify | pack | cleanup) ;;
  *)
    echo "::error ::unsupported Gate 4 phase: $phase"
    exit 2
    ;;
esac

fixture_sha=unknown
if [ -f "${fixture_dir}/SHA256SUMS" ]; then
  fixture_sha="$(awk '$2 == "fixture.nar" { print $1; exit }' "${fixture_dir}/SHA256SUMS")"
fi

emit_event() {
  operation="$1"
  status="$2"
  duration_ms="$3"
  shift 3

  python3 - "$evidence" "$operation" "$status" "$duration_ms" \
    "${GITHUB_SHA:-unknown}" "$fixture_sha" "$variant" "$phase" \
    "${RUNNER_OS:-unknown}" "${ImageOS:-unknown}" "${ImageVersion:-unknown}" \
    "$trial" "${GITHUB_RUN_ID:-unknown}" "${GITHUB_RUN_ATTEMPT:-unknown}" "$@" <<'PY'
import json
import re
import sys

(
    destination,
    operation,
    status,
    duration_ms,
    source_sha,
    fixture_sha,
    candidate,
    phase,
    runner_os,
    runner_image,
    runner_image_version,
    trial,
    github_run_id,
    github_run_attempt,
    *fields,
) = sys.argv[1:]

record = {
    "sourceSha": source_sha,
    "fixtureSha": fixture_sha,
    "candidate": candidate,
    "phase": phase,
    "operation": operation,
    "status": int(status),
    "durationMilliseconds": int(duration_ms),
    "runnerOS": runner_os,
    "runnerImage": runner_image,
    "runnerImageVersion": runner_image_version,
    "trial": trial,
    "generation": 0,
    "githubRunId": github_run_id,
    "githubRunAttempt": github_run_attempt,
}

for field in fields:
    key, value = field.split("=", 1)
    if value in {"true", "false"}:
        value = value == "true"
    elif re.fullmatch(r"-?[0-9]+", value):
        value = int(value)
    record[key] = value

with open(destination, "a", encoding="utf-8") as stream:
    stream.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
PY
}

elapsed_ms() {
  started_ns="$1"
  python3 -c "import time; print((time.time_ns() - ${started_ns}) // 1000000)"
}

run_timed() {
  operation="$1"
  shift
  started_ns="$(python3 -c 'import time; print(time.time_ns())')"
  set +e
  "$@"
  status=$?
  emit_event "$operation" "$status" "$(elapsed_ms "$started_ns")"
  emit_status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  return "$emit_status"
}

die() {
  echo "::error ::$*"
  exit 1
}

phase_exit() {
  status=$?
  trap - EXIT
  set +e
  emit_event "${phase}-complete" "$status" "$(elapsed_ms "$phase_started_ns")"
  emit_status=$?
  if [ "$emit_status" -ne 0 ]; then
    echo "::warning ::failed to record ${phase} completion evidence with status $emit_status"
  fi
  exit "$status"
}
trap phase_exit EXIT

host_free_bytes() {
  df -k "$RUNNER_TEMP" | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

physical_bytes() {
  if [ -e "$image" ]; then
    du -sk "$image" | awk '{ printf "%.0f\n", $1 * 1024 }'
  else
    printf '0\n'
  fi
}

file_count() {
  if [ -d "$image" ]; then
    find "$image" -type f | wc -l | tr -d ' '
  elif [ -f "$image" ]; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

band_count() {
  if [ "$container" = udsb ] && [ -d "${image}/bands" ]; then
    find "${image}/bands" -type f | wc -l | tr -d ' '
  else
    printf '0\n'
  fi
}

guard_host_space() {
  free_bytes="$(host_free_bytes)"
  [ "$free_bytes" -ge $((3 * 1024 * 1024 * 1024)) ] \
    || die "host free space is below 3 GiB: ${free_bytes} bytes"
  emit_event host-space-guard 0 0 "hostFreeBytes=${free_bytes}"
}

guard_physical_image() {
  bytes="$(physical_bytes)"
  [ "$bytes" -le $((8 * 1024 * 1024 * 1024)) ] \
    || die "packed image exceeds 8 GiB: ${bytes} bytes"
  emit_event physical-image-guard 0 0 \
    "physicalBytes=${bytes}" \
    "fileCount=$(file_count)" \
    "bandCount=$(band_count)"
}

prepare_synthetic_nix() {
  synthetic_conf=/etc/synthetic.conf
  sudo touch "$synthetic_conf"

  if grep -qE '^nix($|[[:space:]])' "$synthetic_conf"; then
    grep -qx nix "$synthetic_conf" \
      || die "$synthetic_conf already defines nix differently"
  else
    printf 'nix\n' | sudo tee -a "$synthetic_conf" >/dev/null
  fi

  if ! sudo /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -B >/dev/null 2>&1; then
    sudo /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t >/dev/null 2>&1 || true
  fi

  [ -d /nix ] || die "macOS did not materialise synthetic /nix"
  [ ! -L /nix ] || die "/nix is a symlink"
}

create_image() {
  case "$variant" in
    0-udsb-jhfsx)
      hdiutil create -size 64g -type SPARSEBUNDLE \
        -fs 'Case-sensitive Journaled HFS+' -volname NixStore "$image"
      ;;
    1-udsb-hfsx)
      hdiutil create -size 64g -type SPARSEBUNDLE \
        -fs 'Case-sensitive HFS+' -volname NixStore "$image"
      ;;
    2-udsb-apfsx)
      hdiutil create -size 64g -type SPARSEBUNDLE \
        -fs 'Case-sensitive APFS' -volname NixStore "$image"
      ;;
    3-asif-apfsx)
      diskutil image create blank --format ASIF --size 64GiB \
        --volumeName NixStore --fs APFSX "$image"
      ;;
  esac
}

attach_image() {
  if [ "$container" = asif ]; then
    sudo diskutil image attach --mountPoint /nix --nobrowse "$image"
  else
    sudo hdiutil attach -mountpoint /nix -nobrowse "$image"
  fi
}

image_info() {
  if [ "$container" = asif ]; then
    diskutil image info "$image"
  else
    hdiutil imageinfo "$image"
  fi
}

record_image_info() {
  set +e
  info="$(image_info 2>&1)"
  status=$?
  emit_event image-info "$status" 0 "imageInfo=${info}"
  emit_status=$?
  set -e
  [ "$status" -eq 0 ] || return "$status"
  [ "$emit_status" -eq 0 ] || return "$emit_status"

  if [ "$container" = asif ]; then
    printf '%s\n' "$info" | grep -qi ASIF \
      || die "disk image does not report ASIF"
  else
    printf '%s\n' "$info" | grep -qi UDSB \
      || die "disk image does not report UDSB"
  fi
}

verify_fixture_artifact() {
  for path in fixture.nar fixture-paths.txt roots.tsv target.json SHA256SUMS; do
    [ -f "${fixture_dir}/${path}" ] || die "fixture file is missing: $path"
  done
  (
    cd "$fixture_dir"
    shasum -a 256 -c SHA256SUMS
  )
}

target_field() {
  jq -er ".$1" "${fixture_dir}/target.json"
}

verify_capacity_and_filesystem() {
  disk_info="${work_dir}/diskutil-info-${phase}.plist"
  diskutil info -plist /nix > "$disk_info"
  logical_bytes="$(plutil -extract TotalSize raw "$disk_info")"
  personality="$(plutil -extract FilesystemName raw "$disk_info")"
  owner_uid="$(stat -f '%u' /nix)"
  expected_uid="$(id -u)"

  minimum_bytes=$((64 * 1024 * 1024 * 1024 * 99 / 100))
  maximum_bytes=$((64 * 1024 * 1024 * 1024 * 101 / 100))
  case "$logical_bytes" in
    '' | *[!0-9]*) die "diskutil returned an invalid logical size: $logical_bytes" ;;
  esac
  [ "$logical_bytes" -ge "$minimum_bytes" ] && [ "$logical_bytes" -le "$maximum_bytes" ] \
    || die "logical capacity is not within 1% of 64 GiB: $logical_bytes bytes"
  [ "$owner_uid" = "$expected_uid" ] \
    || die "mounted /nix owner differs from the runner user: ${owner_uid}"

  case "$variant" in
    0-udsb-jhfsx | 1-udsb-hfsx)
      [ "$personality" = "$expected_filesystem" ] \
        || die "unexpected filesystem personality: $personality"
      ;;
    2-udsb-apfsx | 3-asif-apfsx)
      printf '%s\n' "$personality" | grep -q APFS \
        || die "unexpected filesystem personality: $personality"
      ;;
  esac

  case "$expected_journal" in
    true)
      printf '%s\n' "$personality" | grep -q Journaled \
        || die "candidate 0 is not journalled"
      ;;
    false)
      if printf '%s\n' "$personality" | grep -q Journaled; then
        die "candidate 1 unexpectedly reports journalling"
      fi
      ;;
  esac

  emit_event filesystem 0 0 \
    "logicalBytes=${logical_bytes}" \
    "filesystemPersonality=${personality}" \
    "ownerUid=${owner_uid}" \
    "journal=${expected_journal}"
}

create_probes() {
  probe_dir=/nix/gate4-probes
  mkdir -p "$probe_dir"
  printf 'lower\n' > "${probe_dir}/case"
  printf 'upper\n' > "${probe_dir}/CASE"
  printf 'metadata\n' > "${probe_dir}/metadata"
  chmod 0640 "${probe_dir}/metadata"
  xattr -w org.gate4.probe preserved "${probe_dir}/metadata"
  ln "${probe_dir}/metadata" "${probe_dir}/hardlink"
  ln -s metadata "${probe_dir}/symlink"
}

verify_probes() {
  probe_dir=/nix/gate4-probes
  [ "$(cat "${probe_dir}/case")" = lower ] || die "lower-case probe changed"
  [ "$(cat "${probe_dir}/CASE")" = upper ] || die "upper-case probe changed"
  [ "$(stat -f '%i' "${probe_dir}/case")" != "$(stat -f '%i' "${probe_dir}/CASE")" ] \
    || die "case-distinct probes share an inode"
  [ "$(stat -f '%Sp' "${probe_dir}/metadata")" = '-rw-r-----' ] \
    || die "metadata probe mode changed"
  [ "$(xattr -p org.gate4.probe "${probe_dir}/metadata")" = preserved ] \
    || die "metadata probe xattr changed"
  [ "$(stat -f '%i' "${probe_dir}/metadata")" = "$(stat -f '%i' "${probe_dir}/hardlink")" ] \
    || die "hardlink probe inode changed"
  [ "$(stat -f '%l' "${probe_dir}/metadata")" -ge 2 ] \
    || die "hardlink probe link count changed"
  [ "$(readlink "${probe_dir}/symlink")" = metadata ] \
    || die "symlink probe target changed"
  emit_event filesystem-probes 0 0 \
    caseSensitive=true \
    metadata=true \
    hardlink=true \
    symlink=true
}

verify_fixture_closure() {
  drv="$1"
  out="$2"
  actual_paths="${work_dir}/actual-fixture-paths.txt"
  nix-store --query --requisites --include-outputs "$drv" \
    | grep -vFx "$out" \
    | LC_ALL=C sort -u \
    > "$actual_paths"
  cmp "${fixture_dir}/fixture-paths.txt" "$actual_paths" \
    || die "fixture closure manifest changed"
}

verify_roots() {
  actual_roots="${work_dir}/actual-roots.tsv"
  : > "$actual_roots"
  while IFS="$(printf '\t')" read -r name path; do
    root="/nix/var/nix/gcroots/gate4/${name}"
    [ -L "$root" ] || die "fixture root is missing: $name"
    [ "$(readlink "$root")" = "$path" ] || die "fixture root changed: $name"
    printf '%s\t%s\n' "$name" "$(readlink "$root")" >> "$actual_roots"
  done < "${fixture_dir}/roots.tsv"
  cmp "${fixture_dir}/roots.tsv" "$actual_roots" \
    || die "root manifest changed"
}

verify_target_identity() {
  drv="$1"
  expected_out="$2"
  actual_out="$(nix-store --query --outputs "$drv")"
  [ "$actual_out" = "$expected_out" ] \
    || die "target output identity changed: $actual_out"
}

verify_sqlite() {
  result="$(sqlite3 /nix/var/nix/db/db.sqlite 'PRAGMA quick_check;')"
  [ "$result" = ok ] || die "Nix SQLite quick_check failed: $result"
  emit_event sqlite-quick-check 0 0 result=ok
}

verify_nix_store() {
  run_timed nix-legacy-verify nix-store --verify --check-contents
  run_timed nix-modern-verify nix store verify --all --no-trust
}

is_nix_mounted() {
  mount | awk '$3 == "/nix" { found = 1 } END { exit !found }'
}

detach_nix() {
  detach_started_ns="$(python3 -c 'import time; print(time.time_ns())')"
  set +e
  sudo hdiutil detach /nix
  detach_status=$?
  emit_event detach "$detach_status" "$(elapsed_ms "$detach_started_ns")" \
    forcedDetach=false
  emit_status=$?
  set -e

  if [ "$detach_status" -eq 0 ]; then
    return "$emit_status"
  fi

  force_started_ns="$(python3 -c 'import time; print(time.time_ns())')"
  set +e
  sudo hdiutil detach -force /nix
  force_status=$?
  emit_event force-detach "$force_status" "$(elapsed_ms "$force_started_ns")" \
    forcedDetach=true
  set -e
  return "$detach_status"
}

record_installer_baseline() {
  installer_paths="${work_dir}/installer-paths.txt"
  nix path-info --all | LC_ALL=C sort -u > "$installer_paths"
  emit_event installer-baseline 0 0 \
    "pathCount=$(wc -l < "$installer_paths" | tr -d ' ')" \
    "pathsSha256=$(shasum -a 256 "$installer_paths" | awk '{ print $1 }')" \
    "storeBytes=$(du -sk /nix/store | awk '{ printf "%.0f\n", $1 * 1024 }')"
}

record_snapshot() {
  stage="$1"
  nix_version=unknown
  store_bytes=0
  if command -v nix >/dev/null 2>&1; then
    nix_version="$(nix --version)"
  fi
  if [ -d /nix/store ]; then
    store_bytes="$(du -sk /nix/store | awk '{ printf "%.0f\n", $1 * 1024 }')"
  fi
  emit_event snapshot 0 0 \
    "stage=${stage}" \
    "nixVersion=${nix_version}" \
    "hostFreeBytes=$(host_free_bytes)" \
    "physicalBytes=$(physical_bytes)" \
    "fileCount=$(file_count)" \
    "bandCount=$(band_count)" \
    "fixturePathCount=$(wc -l < "${fixture_dir}/fixture-paths.txt" | tr -d ' ')" \
    "rootCount=$(wc -l < "${fixture_dir}/roots.tsv" | tr -d ' ')" \
    "narBytes=$(stat -f '%z' "${fixture_dir}/fixture.nar")" \
    "storeBytes=${store_bytes}"
}

verify_common() {
  expected_out_state="$1"
  drv="$2"
  out="$3"

  verify_capacity_and_filesystem
  verify_probes
  verify_fixture_closure "$drv" "$out"
  verify_roots
  verify_target_identity "$drv" "$out"

  if [ "$expected_out_state" = valid ]; then
    nix-store --check-validity "$out"
    [ -L /nix/var/nix/gcroots/gate4/measured-output ] \
      || die "measured output root is missing"
    [ "$(readlink /nix/var/nix/gcroots/gate4/measured-output)" = "$out" ] \
      || die "measured output root changed"
  else
    if nix-store --check-validity "$out" >/dev/null 2>&1; then
      die "target output is already valid before measured realisation"
    fi
  fi
  target_valid=false
  if [ "$expected_out_state" = valid ]; then
    target_valid=true
  fi
  emit_event target-validity 0 0 \
    "expected=${expected_out_state}" \
    "valid=${target_valid}"

  run_timed diskutil-verify-volume diskutil verifyVolume /nix
  verify_sqlite
  verify_nix_store
}

prepare_phase() {
  verify_fixture_artifact
  guard_host_space
  prepare_synthetic_nix
  mkdir -p "$(dirname "$image")"

  if [ ! -e "$image" ]; then
    run_timed create create_image
  fi

  record_image_info
  run_timed attach attach_image
  sudo chown "$USER" /nix
  chmod u+rwx /nix
  verify_capacity_and_filesystem
  guard_host_space
}

verify_phase() {
  verify_fixture_artifact
  drv="$(target_field drvPath)"
  out="$(target_field outPath)"
  expected_nix_version="$(target_field nixVersion)"
  [ "$(nix --version)" = "$expected_nix_version" ] \
    || die "Nix version differs from fixture: expected $expected_nix_version, got $(nix --version)"

  marker=/nix/var/nix/gate4-initialised
  if [ ! -f "$marker" ]; then
    if nix-store --check-validity "$out" >/dev/null 2>&1; then
      die "target output is already valid before fixture import"
    fi

    record_installer_baseline

    import_fixture() {
      nix-store --import < "${fixture_dir}/fixture.nar"
    }
    run_timed import import_fixture
    verify_fixture_closure "$drv" "$out"

    mkdir -p /nix/var/nix/gcroots/gate4
    while IFS="$(printf '\t')" read -r name path; do
      root="/nix/var/nix/gcroots/gate4/${name}"
      mkdir -p "$(dirname "$root")"
      ln -s "$path" "$root"
    done < "${fixture_dir}/roots.tsv"
    create_probes

    verify_common invalid "$drv" "$out"
    record_snapshot before-realise

    realised_file="${work_dir}/realised-output.txt"
    started_ns="$(python3 -c 'import time; print(time.time_ns())')"
    set +e
    nix-store --option substituters '' --option builders '' --realise "$drv" > "$realised_file"
    status=$?
    set -e
    emit_event realise "$status" "$(elapsed_ms "$started_ns")" \
      "targetValidBefore=false"
    [ "$status" -eq 0 ] || return "$status"
    realised="$(tail -n 1 "$realised_file")"
    [ "$realised" = "$out" ] || die "realised output differs from target: $realised"
    nix-store --check-validity "$out"
    ln -s "$out" /nix/var/nix/gcroots/gate4/measured-output
    printf '%s\n' "$fixture_sha" > "$marker"

    verify_common valid "$drv" "$out"
    record_snapshot after-realise
  else
    [ "$(cat "$marker")" = "$fixture_sha" ] || die "fixture marker changed"
    verify_common valid "$drv" "$out"
    record_snapshot after-reattach
  fi
}

pack_phase() {
  [ -d /nix/store ] || die "/nix is not mounted"
  record_snapshot before-pack
  run_timed gc nix store gc
  run_timed optimise nix store optimise
  run_timed sync sync
  detach_nix

  if [ "$container" = udsb ]; then
    run_timed compact hdiutil compact "$image"
  else
    emit_event compact 0 0 skipped=true
  fi

  record_image_info
  guard_host_space
  guard_physical_image
}

cleanup_phase() {
  if ! is_nix_mounted; then
    emit_event cleanup-detach 0 0 mounted=false forcedDetach=false
    return
  fi
  detach_nix
}

case "$phase" in
  prepare) prepare_phase ;;
  verify) verify_phase ;;
  pack) pack_phase ;;
  cleanup) cleanup_phase ;;
esac
