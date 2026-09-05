#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "::error ::$*" >&2
  exit 1
}

valid_format() {
  case "${1:-}" in
    ext4 | erofs | squashfs) ;;
    *) return 1 ;;
  esac
}

valid_workers() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

valid_boolean() {
  case "${1:-}" in
    true | false) ;;
    *) return 1 ;;
  esac
}

fits_budget() {
  local current="$1" added="$2" limit="$3" reserve="$4"
  ((current + added + reserve <= limit))
}

write_checksum() {
  local image="$1"
  (cd "$(dirname "$image")" && sha256sum "$(basename "$image")" > image.sha256)
}

mount_overlay() {
  local format="$1" image="$2" mount_dir
  valid_format "$format" && [ "$format" != ext4 ] || die "overlay format must be erofs or squashfs"
  [ -f "$image" ] || die "image is missing: $image"
  (cd "$(dirname "$image")" && sha256sum --check image.sha256)
  [ ! -e /nix ] || die "/nix already exists"

  mount_dir="$RUNNER_TEMP/linux-lifecycle-mount-$format"
  mkdir -p "$mount_dir/lower" "$mount_dir/upper" "$mount_dir/work"
  sudo mkdir /nix
  sudo modprobe "$format"
  sudo modprobe overlay
  sudo mount -t "$format" -o loop,ro "$image" "$mount_dir/lower"
  sudo mount -t overlay overlay \
    -o "lowerdir=$mount_dir/lower,upperdir=$mount_dir/upper,workdir=$mount_dir/work" /nix
}

checkpoint_complete() {
  case "${1:-}" in
    0\|*) ;;
    *) return 1 ;;
  esac
}

checkpoint() {
  local database=/nix/var/nix/db/db.sqlite result
  [ -f "$database" ] || die "Nix database is missing: $database"
  result="$(sudo sqlite3 "$database" 'PRAGMA wal_checkpoint(TRUNCATE);')"
  checkpoint_complete "$result" || die "SQLite checkpoint did not complete: $result"
  echo "LINUX_LIFECYCLE_SQLITE_CHECKPOINT result=$result"
  sync
}

freeze() {
  sudo mount -o remount,ro /nix
}

pack_immutable() {
  local format="$1" source="$2" image="$3" workers="$4" squashfs_noi="${5:-false}"
  local -a squashfs_options=()
  valid_format "$format" && [ "$format" != ext4 ] || die "immutable format must be erofs or squashfs"
  valid_workers "$workers" || die "workers must be a positive integer"
  valid_boolean "$squashfs_noi" || die "squashfs_noi must be true or false"
  [ "$format" = squashfs ] || [ "$squashfs_noi" = false ] || die "squashfs_noi only applies to SquashFS"
  [ -d "$source" ] || die "pack source is missing: $source"
  mkdir -p "$(dirname "$image")"
  rm -f "$image" "$(dirname "$image")/image.sha256"

  case "$format" in
    erofs)
      [ -x "${EROFS_MKFS:-}" ] || die "EROFS_MKFS must name an executable"
      sudo "$EROFS_MKFS" --quiet --workers="$workers" -zzstd,level=3 -C65536 \
        -Efragments,ztailpacking "$image" "$source"
      ;;
    squashfs)
      command -v mksquashfs >/dev/null || die "mksquashfs is required"
      [ "$squashfs_noi" = false ] || squashfs_options=(-noI)
      sudo mksquashfs "$source" "$image" -noappend -comp zstd -Xcompression-level 3 \
        -processors "$workers" -no-progress "${squashfs_options[@]}"
      ;;
  esac
  write_checksum "$image"
}

pack_ext4() {
  local raw_image="$1" archive="$2" workers="$3" status=0
  [ -f "$raw_image" ] || die "ext4 image is missing: $raw_image"
  valid_workers "$workers" || die "workers must be a positive integer"
  command -v e2fsck >/dev/null || die "e2fsck is required"
  command -v zstd >/dev/null || die "zstd is required"

  if findmnt -no OPTIONS /nix | grep -Eq '(^|,)rw(,|$)'; then
    sudo fstrim -v /nix || true
  fi
  sync
  sudo umount /nix || die "/nix is still busy"
  sudo e2fsck -pf "$raw_image" || status=$?
  if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then
    die "e2fsck failed with status $status"
  fi
  mkdir -p "$(dirname "$archive")"
  zstd --sparse -T"$workers" -3 -f "$raw_image" -o "$archive"
  write_checksum "$archive"
}

unmount_overlay() {
  local format="$1" mount_dir
  mount_dir="$RUNNER_TEMP/linux-lifecycle-mount-$format"
  sudo umount /nix
  sudo umount "$mount_dir/lower"
}

check_budget() {
  local limit="$1" reserve="$2" current added=0 path bytes
  shift 2
  valid_workers "$limit" && [[ "$reserve" =~ ^[0-9]+$ ]] || die "invalid cache budget"
  [ "$#" -gt 0 ] || die "cache budget needs at least one path"
  current="$(gh cache list --repo "$GITHUB_REPOSITORY" --limit 10000 --json sizeInBytes \
    --jq '[.[].sizeInBytes] | add // 0')"
  for path in "$@"; do
    [ -e "$path" ] || die "cache payload is missing: $path"
    bytes="$(du -sb "$path" | awk '{print $1}')"
    added="$((added + bytes))"
  done
  echo "LINUX_LIFECYCLE_CACHE_BUDGET currentBytes=$current addedBytes=$added reserveBytes=$reserve limitBytes=$limit"
  fits_budget "$current" "$added" "$limit" "$reserve" || die "experiment cache save would exceed its reserved budget"
}

self_test() {
  valid_format ext4
  valid_format erofs
  valid_format squashfs
  if valid_format tar; then return 1; fi
  valid_workers 4
  if valid_workers 0; then return 1; fi
  valid_boolean true
  valid_boolean false
  if valid_boolean yes; then return 1; fi
  fits_budget 10 20 40 5
  if fits_budget 10 30 40 5; then return 1; fi
  checkpoint_complete '0|3|3'
  if checkpoint_complete '1|2|0'; then return 1; fi
}

command="${1:-}"
shift || true
case "$command" in
  budget) check_budget "$@" ;;
  checkpoint) checkpoint "$@" ;;
  freeze) freeze "$@" ;;
  mount-overlay) mount_overlay "$@" ;;
  pack-ext4) pack_ext4 "$@" ;;
  pack-immutable) pack_immutable "$@" ;;
  self-test) self_test ;;
  unmount-overlay) unmount_overlay "$@" ;;
  *) exit 64 ;;
esac
