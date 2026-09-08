#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "::error ::$*" >&2
  exit 1
}

mount_dir() {
  printf '%s/linux-ci-mount-%s\n' "${RUNNER_TEMP:?RUNNER_TEMP is required}" "$1"
}

component_settings() {
  case "${1:-}" in
    linux-seed-x86_64-linux) system=x86_64-linux format=erofs ;;
    linux-full-x86_64-linux) system=x86_64-linux format=squashfs ;;
    linux-full-aarch64-linux) system=aarch64-linux format=squashfs ;;
    *) die "unsupported Linux component: ${1:-}" ;;
  esac
}

canonical_temp_path() {
  local runner path parent
  runner="$(realpath "${RUNNER_TEMP:?RUNNER_TEMP is required}")"
  if [ -e "$1" ] || [ -L "$1" ]; then
    path="$(realpath "$1")"
  else
    parent="$(realpath "$(dirname "$1")")" || return 1
    path="$parent/$(basename "$1")"
  fi
  case "$path" in
    "$runner"/*) printf '%s\n' "$path" ;;
    *) return 1 ;;
  esac
}

remove_temp_path() {
  local path
  path="$(canonical_temp_path "$1")" || die "path must resolve beneath RUNNER_TEMP: $1"
  rm -rf -- "$path"
}

checkpoint_complete() {
  case "${1:-}" in
    0\|*) ;;
    *) return 1 ;;
  esac
}

checkpoint_database() {
  local database="$1" result
  [ -f "$database" ] || die "Nix database is missing: $database"
  result="$(sqlite3 "$database" 'PRAGMA wal_checkpoint(TRUNCATE);')"
  checkpoint_complete "$result" || die "SQLite checkpoint did not complete: $result"
  echo "CI_LINUX_SQLITE_CHECKPOINT result=$result" >&2
  sync
}

cleanup_overlay() {
  local format="$1" root mount root_pre_existing=false status=0
  root=/nix
  mount="$(mount_dir "$format")"
  [ -f "$mount/owned" ] || return 0
  [ ! -f "$mount/root-pre-existing" ] || root_pre_existing=true

  if mountpoint -q "$root"; then
    sudo umount "$root" || status=$?
  fi
  if mountpoint -q "$mount/lower"; then
    sudo umount "$mount/lower" || status=$?
  fi
  if [ "$root_pre_existing" = false ] && [ -d "$root" ] && ! mountpoint -q "$root"; then
    sudo rmdir "$root" || status=$?
  fi
  [ "$status" -ne 0 ] || remove_temp_path "$mount"
  return "$status"
}

mount_overlay() {
  local format="$1" image="$2" root mount
  [ -f "$image" ] || die "verified image is missing: $image"
  root=/nix
  mount="$(mount_dir "$format")"
  [ ! -e "$root" ] || die "$root already exists"
  [ ! -e "$mount" ] || die "mount state already exists: $mount"

  mkdir -p "$mount/lower" "$mount/upper" "$mount/work"
  touch "$mount/owned"
  if ! sudo mkdir "$root" ||
    ! sudo modprobe "$format" ||
    ! sudo modprobe overlay ||
    ! sudo mount -t "$format" -o loop,ro "$image" "$mount/lower" ||
    ! sudo mount -t overlay overlay \
      -o "lowerdir=$mount/lower,upperdir=$mount/upper,workdir=$mount/work" "$root"; then
    cleanup_overlay "$format"
    return 1
  fi
}

nfb_path() {
  local system="$1" root nfb
  root="/nix/var/nix/gcroots/github-ci/$system/nix-fast-build"
  [ -L "$root" ] || die "nix-fast-build root is missing: $root"
  nfb="$(readlink -e "$root")"
  [ -x "$nfb/bin/nix-fast-build" ] || die "cached nix-fast-build is not executable: $nfb"
  "$nfb/bin/nix-fast-build" --help >/dev/null || die "cached nix-fast-build failed --help: $nfb"
  printf '%s\n' "$nfb"
}

validate_database() {
  local database result
  database=/nix/var/nix/db/db.sqlite
  if [ ! -f "$database" ]; then
    echo "::error ::Nix database is missing: $database" >&2
    return 1
  fi
  if ! command -v sqlite3 >/dev/null; then
    echo "::error ::sqlite3 is required to validate the restored Nix database" >&2
    return 1
  fi
  result="$(sqlite3 -readonly -batch "$database" \
    "PRAGMA quick_check; SELECT count(*) FROM sqlite_master WHERE type='table' AND name='ValidPaths';")"
  if [ "$result" != $'ok\n1' ]; then
    echo "::error ::restored Nix database failed validation" >&2
    return 1
  fi
}

restore_mount() {
  local repo="$1" selection="$2" component="$3" directory="$4"
  local system format image result
  component_settings "$component"
  directory="$(canonical_temp_path "$directory")" || die "restore directory must resolve beneath RUNNER_TEMP"
  [ ! -e "$directory" ] || die "restore directory already exists: $directory"
  if ! result="$(python3 .github/scripts/ci_cache_image.py eager \
    --repo "$repo" --selection "$selection" --component "$component" \
    --directory "$directory")"; then
    remove_temp_path "$directory"
    return 1
  fi
  image="$directory/image.dmg"
  if ! mount_overlay "$format" "$image"; then
    [ -f "$(mount_dir "$format")/owned" ] || remove_temp_path "$directory"
    return 1
  fi
  if ! validate_database; then
    cleanup_overlay "$format" || return
    remove_temp_path "$directory"
    return 1
  fi
  printf '%s\n' "$result" > "$directory/eager.json"
}

validate_mounted() {
  local system format root links
  component_settings "$1"
  root=/nix
  mountpoint -q "$root" || die "$root is not mounted"
  nfb_path "$system" >/dev/null
  [ "$(nix config show auto-optimise-store)" = false ] || die "automatic Nix store optimisation is enabled"
  if [ "$format" = squashfs ]; then
    links="$root/store/.links"
    [ ! -d "$links" ] || [ -z "$(find "$links" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
      die "Nix store optimisation index is not empty"
  fi
  echo "CI_LINUX_IMAGE_VALID format=$format"
}

pack_full() {
  local image="$1" workers="$2" root mount options
  [[ "$workers" =~ ^[1-9][0-9]*$ ]] || die "workers must be a positive integer"
  root=/nix
  mount="$(mount_dir squashfs)"
  if [ ! -f "$mount/owned" ]; then
    [ -d "$root" ] || die "Nix store is missing: $root"
    [ ! -e "$mount" ] || die "unowned mount state already exists: $mount"
    mkdir -p "$mount"
    touch "$mount/owned" "$mount/root-pre-existing"
    if ! sudo mount --bind "$root" "$root"; then
      remove_temp_path "$mount"
      return 1
    fi
  fi
  checkpoint_database "$root/var/nix/db/db.sqlite"
  if [ -f "$mount/root-pre-existing" ]; then
    sudo mount -o remount,bind,ro "$root"
  else
    sudo mount -o remount,ro "$root"
  fi
  options="$(findmnt -no OPTIONS "$root")"
  [[ ",$options," == *,ro,* ]] || die "$root must be read-only before packing"
  [ ! -e "$image" ] || die "immutable output already exists: $image"
  command -v mksquashfs >/dev/null || die "mksquashfs is required"
  mkdir -p "$(dirname "$image")"
  sudo mksquashfs "$root" "$image" -noappend -comp zstd -Xcompression-level 3 \
    -processors "$workers" -no-progress -wildcards -e 'store/.links/*'
}

pack_seed() {
  local system="$1" output="$2" store="$3" packer="$4" full_roots checkout_root
  local nfb name path index destination_roots
  local -a names=() roots=()
  [ "$system" = x86_64-linux ] || die "the selected evaluator seed is x86_64-linux only"
  if ! output="$(canonical_temp_path "$output")" || ! store="$(canonical_temp_path "$store")"; then
    die "seed paths must be beneath RUNNER_TEMP"
  fi
  [ ! -e "$output" ] || die "seed output already exists: $output"
  [ ! -e "$store" ] || die "seed store already exists: $store"
  [ -x "$packer" ] || die "mkfs.erofs is not executable: $packer"
  full_roots="/nix/var/nix/gcroots/github-ci/$system"
  [ -d "$full_roots" ] || die "full root directory is missing: $full_roots"
  checkout_root="$(nix flake archive --json path:. | jq -er .path)"

  for path in "$full_roots"/nix-fast-build "$full_roots"/flake-input-*; do
    [ -L "$path" ] || continue
    name="${path##*/}"
    path="$(readlink -e "$path")"
    [ "$path" != "$checkout_root" ] || die "current checkout root must not enter the seed"
    [[ "$path" =~ ^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$ ]] ||
      die "unsafe seed store path: $path"
    names+=("$name")
    roots+=("$path")
  done
  [ "${#roots[@]}" -gt 1 ] || die "seed requires nix-fast-build and external flake inputs"
  nfb="$(readlink -e "$full_roots/nix-fast-build")"
  if [ ! -x "$nfb/bin/nix-fast-build" ] || ! "$nfb/bin/nix-fast-build" --help >/dev/null; then
    die "nix-fast-build seed root is unusable"
  fi
  nix path-info "${roots[@]}" >/dev/null

  mkdir -p "$output"
  nix copy --no-check-sigs --option auto-optimise-store false --to "$store" "${roots[@]}"
  nix path-info --store "$store" --recursive "$nfb" >/dev/null
  destination_roots="$store/nix/var/nix/gcroots/github-ci/$system"
  mkdir -p "$destination_roots"
  for index in "${!names[@]}"; do
    ln -sfn "${roots[$index]}" "$destination_roots/${names[$index]}"
  done

  checkpoint_database "$store/nix/var/nix/db/db.sqlite"
  "$packer" --quiet --workers=1 -zzstd,level=3 -C65536 \
    -Efragments,ztailpacking,dedupe "$output/image" "$store/nix"
}

command="${1:-}"
shift || true
case "$command" in
  cleanup-component) component_settings "$1"; cleanup_overlay "$format" ;;
  discard-temp) remove_temp_path "$@" ;;
  pack-full) pack_full "$@" ;;
  pack-seed) pack_seed "$@" ;;
  restore-mount) restore_mount "$@" ;;
  validate-mounted) validate_mounted "$@" ;;
  *) exit 64 ;;
esac
