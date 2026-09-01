#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=.github/scripts/gate4-darwin-storage-screen.sh
source "${script_dir}/gate4-darwin-storage-screen.sh"

variant=4-ulfo-shadow-apfsx
phase=probe
fixture_dir="${RUNNER_TEMP:?RUNNER_TEMP must be set}/gate4-fixture"
work_dir="${RUNNER_TEMP}/gate4/${variant}/probe"
seed="${work_dir}/seed.udrw.dmg"
base="${work_dir}/base.ulfo.dmg"
shadow="${work_dir}/shadow"
image="$base"
trial=probe
evidence="${work_dir}/evidence.jsonl"
phase_started_ns="$(python3 -c 'import time; print(time.time_ns())')"
fixture_sha=unknown
container=ulfo
expected_filesystem=APFS
expected_journal=na
cleanup_on_exit=true

mkdir -p "$work_dir"
touch "$evidence"
if [ -f "${fixture_dir}/SHA256SUMS" ]; then
  fixture_sha="$(awk '$2 == "fixture.nar" { print $1; exit }' "${fixture_dir}/SHA256SUMS")"
fi

allocated_bytes() {
  du -sk "$1" | awk '{print $1 * 1024}'
}

logical_bytes() {
  stat -f '%z' "$1"
}

physical_bytes() {
  total=0
  for path in "$seed" "$base" "$shadow"; do
    if [ -e "$path" ]; then
      bytes="$(allocated_bytes "$path")"
      total=$((total + bytes))
    fi
  done
  printf '%s\n' "$total"
}

file_count() {
  count=0
  for path in "$seed" "$base" "$shadow"; do
    [ -e "$path" ] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

band_count() {
  printf '0\n'
}

pair_file_count() {
  count=0
  for path in "$base" "$shadow"; do
    [ -e "$path" ] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

record_seed_accounting() {
  emit_event accounting 0 0 \
    stage=seed-created \
    "seedPhysicalBytes=$(allocated_bytes "$seed")" \
    "seedLogicalBytes=$(logical_bytes "$seed")" \
    "hostFreeBytes=$(host_free_bytes)"
}

record_pair_accounting() {
  stage="$1"
  base_physical=0
  base_logical=0
  shadow_physical=0
  shadow_logical=0
  [ -e "$base" ] && base_physical="$(allocated_bytes "$base")"
  [ -e "$base" ] && base_logical="$(logical_bytes "$base")"
  [ -e "$shadow" ] && shadow_physical="$(allocated_bytes "$shadow")"
  [ -e "$shadow" ] && shadow_logical="$(logical_bytes "$shadow")"
  combined_physical=$((base_physical + shadow_physical))
  free_bytes="$(host_free_bytes)"
  emit_event accounting 0 0 \
    "stage=${stage}" \
    "basePhysicalBytes=${base_physical}" \
    "shadowPhysicalBytes=${shadow_physical}" \
    "combinedPhysicalBytes=${combined_physical}" \
    "baseLogicalBytes=${base_logical}" \
    "shadowLogicalBytes=${shadow_logical}" \
    "fileCount=$(pair_file_count)" \
    "hostFreeBytes=${free_bytes}"
  [ "$free_bytes" -ge $((3 * 1024 * 1024 * 1024)) ] \
    || die "host free space is below 3 GiB: ${free_bytes} bytes"
}

guard_pair_physical() {
  stage="$1"
  base_physical=0
  shadow_physical=0
  [ -e "$base" ] && base_physical="$(allocated_bytes "$base")"
  [ -e "$shadow" ] && shadow_physical="$(allocated_bytes "$shadow")"
  combined_physical=$((base_physical + shadow_physical))
  [ "$combined_physical" -le $((8 * 1024 * 1024 * 1024)) ] \
    || die "base plus shadow exceeds 8 GiB: ${combined_physical} bytes"
  emit_event physical-image-guard 0 0 \
    "stage=${stage}" \
    "basePhysicalBytes=${base_physical}" \
    "shadowPhysicalBytes=${shadow_physical}" \
    "combinedPhysicalBytes=${combined_physical}"
}

guard_pair_space() {
  guard_host_space
  record_pair_accounting "$1"
}

record_ulfo_info() {
  info="$(hdiutil imageinfo "$base" 2>&1)" || die "ULFO imageinfo failed"
  emit_event image-info 0 0 "imageInfo=${info}"
  [ "$(hdiutil imageinfo -format "$base")" = ULFO ] \
    || die "disk image does not report ULFO"
}

detach_probe() {
  detach_started_ns="$(python3 -c 'import time; print(time.time_ns())')"
  detach_status=0
  sudo hdiutil detach /nix || detach_status=$?
  emit_status=0
  emit_event detach "$detach_status" "$(elapsed_ms "$detach_started_ns")" forcedDetach=false \
    || emit_status=$?
  [ "$detach_status" -eq 0 ] || return "$detach_status"
  return "$emit_status"
}

cleanup_probe() {
  status=$?
  trap - EXIT
  set +e
  if [ "${cleanup_on_exit}" = true ] && is_nix_mounted; then
    detach_probe
    detach_status=$?
    [ "$status" -ne 0 ] || status="$detach_status"
  fi
  emit_event probe-complete "$status" "$(elapsed_ms "$phase_started_ns")"
  exit "$status"
}
trap cleanup_probe EXIT

create_seed() {
  [ ! -e "$seed" ] || die "seed already exists"
  hdiutil create -size 64g -type UDIF \
    -fs 'Case-sensitive APFS' -volname NixStore "$seed"
  [ "$(hdiutil imageinfo -format "$seed")" = UDRW ] \
    || die "seed image does not report UDRW"
  emit_event create 0 0 state=seed-created
  record_seed_accounting
  guard_host_space
  sudo hdiutil attach -readwrite -mountpoint /nix -nobrowse "$seed"
  sudo chown "$USER" /nix
  chmod u+rwx /nix
  verify_capacity_and_filesystem
}

seed_phase() {
  verify_fixture_artifact
  guard_host_space
  prepare_synthetic_nix
  create_seed
  guard_host_space
  cleanup_on_exit=false
}

import_and_verify_seed() {
  verify_fixture_artifact
  drv="$(target_field drvPath)"
  out="$(target_field outPath)"
  expected_nix_version="$(target_field nixVersion)"
  [ "$(nix --version)" = "$expected_nix_version" ] \
    || die "Nix version differs from fixture: expected $expected_nix_version, got $(nix --version)"
  nix-store --check-validity "$out" >/dev/null 2>&1 \
    && die "target output is already valid before fixture import"

  record_installer_baseline
  run_timed import nix-store --import < "${fixture_dir}/fixture.nar"
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
}

realise_shadow() {
  realised_file="${work_dir}/realised-output.txt"
  started_ns="$(python3 -c 'import time; print(time.time_ns())')"
  set +e
  nix-store --option substituters '' --option builders '' --realise "$drv" > "$realised_file"
  status=$?
  set -e
  emit_event realise "$status" "$(elapsed_ms "$started_ns")" targetValidBefore=false
  [ "$status" -eq 0 ] || return "$status"
  realised="$(tail -n 1 "$realised_file")"
  [ "$realised" = "$out" ] || die "realised output differs from target: $realised"
  nix-store --check-validity "$out"
  ln -s "$out" /nix/var/nix/gcroots/gate4/measured-output
  verify_common valid "$drv" "$out"
}

lifecycle_phase() {
  verify_fixture_artifact
  is_nix_mounted || die "seed is not mounted"
  import_and_verify_seed
  detach_probe
  emit_event state 0 0 state=seed-verified

  guard_pair_space before-convert
  run_timed convert hdiutil convert "$seed" -format ULFO -o "$base"
  guard_host_space
  record_ulfo_info
  base_sha_before="$(shasum -a 256 "$base" | awk '{print $1}')"
  rm -f "$seed"
  guard_pair_space base-created
  guard_pair_physical base-created
  emit_event state 0 0 state=base-created "baseSha256=${base_sha_before}"

  [ ! -e "$shadow" ] || die "shadow already exists"
  sudo hdiutil attach -shadow "$shadow" -mountpoint /nix -nobrowse "$base"
  sudo chown "$USER" /nix
  chmod u+rwx /nix
  [ "$(shasum -a 256 "$base" | awk '{print $1}')" = "$base_sha_before" ] \
    || die "ULFO base changed during shadow attach"
  verify_common invalid "$drv" "$out"
  realise_shadow
  run_timed gc nix store gc
  run_timed optimise nix store optimise
  run_timed sync sync
  detach_probe
  [ -e "$shadow" ] || die "shadow was not created"
  [ "$(shasum -a 256 "$base" | awk '{print $1}')" = "$base_sha_before" ] \
    || die "ULFO base changed during shadow mutation"
  record_pair_accounting shadow-mutated
  shadow_sha_mutated="$(shasum -a 256 "$shadow" | awk '{print $1}')"
  emit_event state 0 0 \
    state=shadow-mutated \
    "baseSha256=${base_sha_before}" \
    "shadowSha256=${shadow_sha_mutated}"

  guard_pair_space before-compact
  run_timed compact hdiutil compact "$base" -shadow "$shadow"
  [ "$(shasum -a 256 "$base" | awk '{print $1}')" = "$base_sha_before" ] \
    || die "ULFO base changed during shadow compact"
  record_ulfo_info
  record_pair_accounting persisted
  guard_pair_physical persisted
  shadow_sha_persisted="$(shasum -a 256 "$shadow" | awk '{print $1}')"
  emit_event state 0 0 \
    state=persisted \
    "baseSha256=${base_sha_before}" \
    "shadowSha256=${shadow_sha_persisted}"

  guard_pair_space before-reattach
  sudo hdiutil attach -shadow "$shadow" -mountpoint /nix -nobrowse "$base"
  sudo chown "$USER" /nix
  chmod u+rwx /nix
  verify_common valid "$drv" "$out"
  detach_probe
  [ "$(shasum -a 256 "$base" | awk '{print $1}')" = "$base_sha_before" ] \
    || die "ULFO base changed during final reattach"
  record_pair_accounting reattached-verified
  guard_pair_physical reattached-verified
  shadow_sha_verified="$(shasum -a 256 "$shadow" | awk '{print $1}')"
  emit_event state 0 0 \
    state=reattached-verified \
    "baseSha256=${base_sha_before}" \
    "shadowSha256=${shadow_sha_verified}"
}

cleanup_phase() {
  if is_nix_mounted; then
    detach_probe
  else
    emit_event cleanup-detach 0 0 mounted=false forcedDetach=false
  fi
}

case "${GATE4_ULFO_PHASE:?GATE4_ULFO_PHASE must be set}" in
  seed) seed_phase ;;
  lifecycle) lifecycle_phase ;;
  cleanup) cleanup_phase ;;
  *) die "unsupported ULFO probe phase: ${GATE4_ULFO_PHASE}" ;;
esac
