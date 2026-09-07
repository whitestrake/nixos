#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "::error ::$*" >&2
  exit 1
}

nix_dir() {
  printf '%s\n' "${CI_LINUX_NIX_DIR:-/nix}"
}

mount_dir() {
  printf '%s/linux-ci-mount-%s\n' "${RUNNER_TEMP:?RUNNER_TEMP is required}" "$1"
}

valid_format() {
  case "${1:-}" in
    erofs | squashfs) ;;
    *) return 1 ;;
  esac
}

valid_system() {
  case "${1:-}" in
    x86_64-linux | aarch64-linux) ;;
    *) return 1 ;;
  esac
}

valid_component() {
  case "${1:-}:${2:-}" in
    linux-seed-x86_64-linux:erofs | linux-full-x86_64-linux:squashfs | linux-full-aarch64-linux:squashfs) ;;
    *) return 1 ;;
  esac
}

owned_temp_path() {
  case "$1" in
    "$RUNNER_TEMP"/*) ;;
    *) return 1 ;;
  esac
  [ "$1" != "$RUNNER_TEMP" ]
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
  result="$(sudo sqlite3 "$database" 'PRAGMA wal_checkpoint(TRUNCATE);')"
  checkpoint_complete "$result" || die "SQLite checkpoint did not complete: $result"
  echo "CI_LINUX_SQLITE_CHECKPOINT result=$result" >&2
  sync
}

cleanup_overlay() {
  local format="$1" root mount status=0
  valid_format "$format" || die "format must be erofs or squashfs"
  root="$(nix_dir)"
  mount="$(mount_dir "$format")"
  [ -f "$mount/owned" ] || return 0

  if mountpoint -q "$root"; then
    sudo umount "$root" || status=$?
  fi
  if mountpoint -q "$mount/lower"; then
    sudo umount "$mount/lower" || status=$?
  fi
  if [ -d "$root" ] && ! mountpoint -q "$root"; then
    sudo rmdir "$root" || status=$?
  fi
  [ "$status" -ne 0 ] || rm -f "$mount/owned" "$mount/checkpointed" "$mount/frozen"
  return "$status"
}

mount_overlay() {
  local format="$1" image="$2" root mount
  valid_format "$format" || die "format must be erofs or squashfs"
  [ -f "$image" ] || die "verified image is missing: $image"
  root="$(nix_dir)"
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
  valid_system "$system" || die "unsupported Linux system: $system"
  root="$(nix_dir)/var/nix/gcroots/github-ci/$system/nix-fast-build"
  [ -L "$root" ] || die "nix-fast-build root is missing: $root"
  nfb="$(readlink -e "$root")"
  [ -x "$nfb/bin/nix-fast-build" ] || die "cached nix-fast-build is not executable: $nfb"
  "$nfb/bin/nix-fast-build" --help >/dev/null || die "cached nix-fast-build failed --help: $nfb"
  printf '%s\n' "$nfb"
}

validate_database() {
  local database result
  database="$(nix_dir)/var/nix/db/db.sqlite"
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
  local repo="$1" selection="$2" component="$3" format="$4" directory="$5" workers="$6"
  local system image result nfb
  valid_component "$component" "$format" || die "component and filesystem format do not match"
  [[ "$workers" =~ ^[1-4]$ ]] || die "workers must be 1..4"
  owned_temp_path "$directory" || die "restore directory must be beneath RUNNER_TEMP"
  [ ! -e "$directory" ] || die "restore directory already exists: $directory"
  result="$RUNNER_TEMP/ci-linux-eager-$$.json"
  rm -f "$result"

  if ! python3 .github/scripts/ci_cache_image.py eager \
    --repo "$repo" --selection "$selection" --component "$component" \
    --directory "$directory" --workers "$workers" > "$result"; then
    rm -f "$result"
    rm -rf "$directory"
    return 1
  fi
  image="$directory/image.dmg"
  if ! mount_overlay "$format" "$image"; then
    rm -f "$result"
    [ -f "$(mount_dir "$format")/owned" ] || rm -rf "$directory"
    return 1
  fi
  case "$component" in
    linux-seed-x86_64-linux) system=x86_64-linux ;;
    linux-full-x86_64-linux) system=x86_64-linux ;;
    linux-full-aarch64-linux) system=aarch64-linux ;;
  esac
  if ! validate_database; then
    cleanup_overlay "$format" || return
    rm -f "$result"
    rm -rf "$directory"
    return 1
  fi
  if ! nfb="$(nfb_path "$system")"; then
    cleanup_overlay "$format" || return
    rm -f "$result"
    rm -rf "$directory"
    return 1
  fi
  mv "$result" "$directory/eager.json"
  jq -cn --arg image "$image" --arg nfb "$nfb/bin/nix-fast-build" \
    --arg component "$component" '{restored:true,image:$image,nixFastBuild:$nfb,component:$component}'
}

validate_mounted() {
  local system="$1" format="$2" root links nfb
  valid_system "$system" || die "unsupported Linux system: $system"
  valid_format "$format" || die "format must be erofs or squashfs"
  root="$(nix_dir)"
  mountpoint -q "$root" || die "$root is not mounted"
  nfb="$(nfb_path "$system")"
  [ "$(nix config show auto-optimise-store)" = false ] || die "automatic Nix store optimisation is enabled"
  if [ "$format" = squashfs ]; then
    links="$root/store/.links"
    [ ! -d "$links" ] || [ -z "$(find "$links" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
      die "Nix store optimisation index is not empty"
  fi
  jq -cn --arg nfb "$nfb/bin/nix-fast-build" --arg format "$format" \
    '{valid:true,nixFastBuild:$nfb,format:$format}'
}

checkpoint_full() {
  local format="$1" mount
  valid_format "$format" || die "format must be erofs or squashfs"
  mount="$(mount_dir "$format")"
  [ -f "$mount/owned" ] || die "Linux image mount is not owned by this helper"
  checkpoint_database "$(nix_dir)/var/nix/db/db.sqlite"
  touch "$mount/checkpointed"
}

freeze_full() {
  local format="$1" mount
  valid_format "$format" || die "format must be erofs or squashfs"
  mount="$(mount_dir "$format")"
  [ -f "$mount/checkpointed" ] || die "checkpoint must complete before freeze"
  sudo mount -o remount,ro "$(nix_dir)"
  touch "$mount/frozen"
}

write_checksum() {
  local image="$1"
  (cd "$(dirname "$image")" && sha256sum "$(basename "$image")" > image.sha256)
}

pack_full() {
  local image="$1" workers="$2" root mount options
  [[ "$workers" =~ ^[1-9][0-9]*$ ]] || die "workers must be a positive integer"
  root="$(nix_dir)"
  mount="$(mount_dir squashfs)"
  [ -f "$mount/frozen" ] || die "freeze must complete before packing"
  options="$(findmnt -no OPTIONS "$root")"
  [[ ",$options," == *,ro,* ]] || die "$root must be read-only before packing"
  [ ! -e "$image" ] || die "immutable output already exists: $image"
  command -v mksquashfs >/dev/null || die "mksquashfs is required"
  mkdir -p "$(dirname "$image")"
  sudo mksquashfs "$root" "$image" -noappend -comp zstd -Xcompression-level 3 \
    -processors "$workers" -no-progress -wildcards -e 'store/.links/*'
  write_checksum "$image"
}

pack_seed() {
  local system="$1" output="$2" store="$3" packer="$4" full_roots checkout_root
  local nfb name path index destination_roots
  local -a names=() roots=()
  valid_system "$system" || die "unsupported Linux system: $system"
  [ "$system" = x86_64-linux ] || die "the selected evaluator seed is x86_64-linux only"
  if ! owned_temp_path "$output" || ! owned_temp_path "$store"; then
    die "seed paths must be beneath RUNNER_TEMP"
  fi
  [ ! -e "$output" ] || die "seed output already exists: $output"
  [ ! -e "$store" ] || die "seed store already exists: $store"
  [ -x "$packer" ] || die "mkfs.erofs is not executable: $packer"
  full_roots="$(nix_dir)/var/nix/gcroots/github-ci/$system"
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
  printf '%s\n' "$nfb" > "$output/nfb-path.txt"
  sudo nix copy --no-check-sigs --option auto-optimise-store false --to "$store" "${roots[@]}"
  sudo nix path-info --store "$store" --recursive "$nfb" >/dev/null
  destination_roots="$store/nix/var/nix/gcroots/github-ci/$system"
  sudo mkdir -p "$destination_roots"
  for index in "${!names[@]}"; do
    sudo ln -sfn "${roots[$index]}" "$destination_roots/${names[$index]}"
  done

  checkpoint_database "$store/nix/var/nix/db/db.sqlite"
  sudo "$packer" --quiet --workers=1 -zzstd,level=3 -C65536 \
    -Efragments,ztailpacking,dedupe "$output/image" "$store/nix"
  write_checksum "$output/image"
}

self_test() {
  checkpoint_complete '0|3|3'
  if checkpoint_complete '1|2|0'; then return 1; fi

  local scratch log
  scratch="$(mktemp -d)"
  log="$scratch/commands"
  mkdir -p "$scratch/linux-ci-mount-erofs/lower" "$scratch/nix" "$scratch/bin"
  touch "$scratch/linux-ci-mount-erofs/owned"
  cat > "$scratch/bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  */lower) exit 0 ;;
  *) exit 1 ;;
esac
EOF
  cat > "$scratch/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CI_LINUX_TEST_LOG"
EOF
  chmod +x "$scratch/bin/mountpoint" "$scratch/bin/sudo"
  PATH="$scratch/bin:$PATH" RUNNER_TEMP="$scratch" CI_LINUX_NIX_DIR="$scratch/nix" \
    CI_LINUX_TEST_LOG="$log" cleanup_overlay erofs
  [ "$(cat "$log")" = "umount $scratch/linux-ci-mount-erofs/lower
rmdir $scratch/nix" ]
  rm -rf "$scratch"
}

command="${1:-}"
shift || true
case "$command" in
  checkpoint) checkpoint_full "$@" ;;
  cleanup) cleanup_overlay "$@" ;;
  freeze) freeze_full "$@" ;;
  pack-full) pack_full "$@" ;;
  pack-seed) pack_seed "$@" ;;
  restore-mount) restore_mount "$@" ;;
  self-test) self_test ;;
  validate-mounted) validate_mounted "$@" ;;
  *) exit 64 ;;
esac
