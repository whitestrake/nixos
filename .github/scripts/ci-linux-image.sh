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
  valid_format "$format" || die "format must be erofs or squashfs"
  root="$(nix_dir)"
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
  directory="$(canonical_temp_path "$directory")" || die "restore directory must resolve beneath RUNNER_TEMP"
  [ ! -e "$directory" ] || die "restore directory already exists: $directory"
  result="$RUNNER_TEMP/ci-linux-eager-$$.json"
  rm -f "$result"

  if ! python3 .github/scripts/ci_cache_image.py eager \
    --repo "$repo" --selection "$selection" --component "$component" \
    --directory "$directory" --workers "$workers" > "$result"; then
    rm -f "$result"
    remove_temp_path "$directory"
    return 1
  fi
  image="$directory/image.dmg"
  if ! mount_overlay "$format" "$image"; then
    rm -f "$result"
    [ -f "$(mount_dir "$format")/owned" ] || remove_temp_path "$directory"
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
    remove_temp_path "$directory"
    return 1
  fi
  if ! nfb="$(nfb_path "$system")"; then
    cleanup_overlay "$format" || return
    rm -f "$result"
    remove_temp_path "$directory"
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
  local format="$1" root mount
  valid_format "$format" || die "format must be erofs or squashfs"
  mount="$(mount_dir "$format")"
  root="$(nix_dir)"
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
  touch "$mount/checkpointed"
}

freeze_full() {
  local format="$1" root mount
  valid_format "$format" || die "format must be erofs or squashfs"
  mount="$(mount_dir "$format")"
  root="$(nix_dir)"
  [ -f "$mount/checkpointed" ] || die "checkpoint must complete before freeze"
  if [ -f "$mount/root-pre-existing" ]; then
    sudo mount -o remount,bind,ro "$root"
  else
    sudo mount -o remount,ro "$root"
  fi
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

copy_seed_store() {
  local store="$1" nfb="$2"
  shift 2
  nix copy --no-check-sigs --option auto-optimise-store false --to "$store" "$@"
  nix path-info --store "$store" --recursive "$nfb" >/dev/null
}

pack_seed() {
  local system="$1" output="$2" store="$3" packer="$4" full_roots checkout_root
  local nfb name path index destination_roots
  local -a names=() roots=()
  valid_system "$system" || die "unsupported Linux system: $system"
  [ "$system" = x86_64-linux ] || die "the selected evaluator seed is x86_64-linux only"
  if ! output="$(canonical_temp_path "$output")" || ! store="$(canonical_temp_path "$store")"; then
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
  copy_seed_store "$store" "$nfb" "${roots[@]}"
  destination_roots="$store/nix/var/nix/gcroots/github-ci/$system"
  mkdir -p "$destination_roots"
  for index in "${!names[@]}"; do
    ln -sfn "${roots[$index]}" "$destination_roots/${names[$index]}"
  done

  checkpoint_database "$store/nix/var/nix/db/db.sqlite"
  "$packer" --quiet --workers=1 -zzstd,level=3 -C65536 \
    -Efragments,ztailpacking,dedupe "$output/image" "$store/nix"
  write_checksum "$output/image"
}

self_test() {
  checkpoint_complete '0|3|3'
  if checkpoint_complete '1|2|0'; then return 1; fi

  local scratch runner outside log
  scratch="$(mktemp -d)"
  runner="$scratch/runner"
  outside="$scratch/outside"
  log="$scratch/commands"
  mkdir -p "$runner" "$outside/keep" "$scratch/nix/var/nix/db" "$scratch/bin"
  touch "$scratch/nix/var/nix/db/db.sqlite"
  ln -s "$outside" "$runner/escape"
  RUNNER_TEMP="$runner" canonical_temp_path "$runner/work" >/dev/null
  if RUNNER_TEMP="$runner" canonical_temp_path "$runner" >/dev/null 2>&1; then return 1; fi
  if RUNNER_TEMP="$runner" canonical_temp_path "$runner/../outside" >/dev/null 2>&1; then return 1; fi
  if RUNNER_TEMP="$runner" canonical_temp_path "$runner/escape/keep" >/dev/null 2>&1; then return 1; fi
  if (RUNNER_TEMP="$runner" remove_temp_path "$runner/escape/keep" >/dev/null 2>&1); then return 1; fi
  [ -e "$outside/keep" ]

  cat > "$scratch/bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
target="${*: -1}"
[ "$target" = "$CI_LINUX_TEST_NIX" ] && [ -f "$CI_LINUX_TEST_ROOT_MOUNTED" ] && exit 0
[ "$target" = "$CI_LINUX_TEST_LOWER" ] && [ -f "$CI_LINUX_TEST_LOWER_MOUNTED" ] && exit 0
exit 1
EOF
  cat > "$scratch/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CI_LINUX_TEST_LOG"
case "$1" in
  mount)
    [ "${2:-}" != --bind ] || touch "$CI_LINUX_TEST_ROOT_MOUNTED"
    ;;
  rmdir) rmdir "$2" ;;
  umount)
    [ "${CI_LINUX_TEST_FAIL_UMOUNT:-}" != "$2" ] || exit 1
    [ "$2" != "$CI_LINUX_TEST_NIX" ] || rm -f "$CI_LINUX_TEST_ROOT_MOUNTED"
    [ "$2" != "$CI_LINUX_TEST_LOWER" ] || rm -f "$CI_LINUX_TEST_LOWER_MOUNTED"
    ;;
esac
EOF
  cat > "$scratch/bin/nix" <<'EOF'
#!/usr/bin/env bash
printf 'nix %s\n' "$*" >> "$CI_LINUX_TEST_LOG"
if [ "$1" = copy ]; then
  mkdir -p "$CI_LINUX_TEST_SEED_STORE/nix/var/nix/db" "$CI_LINUX_TEST_SEED_STORE/nix/store"
  touch "$CI_LINUX_TEST_SEED_STORE/nix/var/nix/db/db.sqlite"
fi
EOF
  cat > "$scratch/bin/sqlite3" <<'EOF'
#!/usr/bin/env bash
printf 'sqlite3 %s\n' "$*" >> "$CI_LINUX_TEST_LOG"
printf '%s\n' '0|0|0'
EOF
  chmod +x "$scratch/bin/mountpoint" "$scratch/bin/nix" "$scratch/bin/sqlite3" "$scratch/bin/sudo"

  export PATH="$scratch/bin:$PATH" RUNNER_TEMP="$runner" CI_LINUX_NIX_DIR="$scratch/nix"
  export CI_LINUX_TEST_LOG="$log" CI_LINUX_TEST_NIX="$scratch/nix"
  export CI_LINUX_TEST_LOWER="$runner/linux-ci-mount-squashfs/lower"
  export CI_LINUX_TEST_ROOT_MOUNTED="$scratch/root-mounted"
  export CI_LINUX_TEST_LOWER_MOUNTED="$scratch/lower-mounted"
  export CI_LINUX_TEST_SEED_STORE="$runner/seed-store"
  checkpoint_full squashfs
  freeze_full squashfs
  [ -f "$runner/linux-ci-mount-squashfs/root-pre-existing" ]
  cleanup_overlay squashfs
  [ -d "$scratch/nix" ]
  [ ! -e "$runner/linux-ci-mount-squashfs" ]
  [ "$(sed -n '1p' "$log")" = "mount --bind $scratch/nix $scratch/nix" ]
  grep -Fqx "mount -o remount,bind,ro $scratch/nix" "$log"

  : > "$log"
  mkdir -p "$runner/linux-ci-mount-erofs/lower" "$runner/linux-ci-mount-erofs/upper/dead" \
    "$runner/linux-ci-mount-erofs/work" "$scratch/warm-nix"
  touch "$runner/linux-ci-mount-erofs/owned" "$CI_LINUX_TEST_LOWER_MOUNTED"
  CI_LINUX_NIX_DIR="$scratch/warm-nix" CI_LINUX_TEST_NIX="$scratch/warm-nix" \
    CI_LINUX_TEST_LOWER="$runner/linux-ci-mount-erofs/lower" cleanup_overlay erofs
  [ ! -e "$runner/linux-ci-mount-erofs" ]
  [ ! -e "$scratch/warm-nix" ]
  [ -e "$outside/keep" ]

  mkdir -p "$runner/linux-ci-mount-erofs/upper/dead" "$scratch/failed-nix"
  touch "$runner/linux-ci-mount-erofs/owned" "$CI_LINUX_TEST_ROOT_MOUNTED"
  if CI_LINUX_NIX_DIR="$scratch/failed-nix" CI_LINUX_TEST_NIX="$scratch/failed-nix" \
    CI_LINUX_TEST_FAIL_UMOUNT="$scratch/failed-nix" cleanup_overlay erofs; then
    return 1
  fi
  [ -e "$runner/linux-ci-mount-erofs/upper/dead" ]

  : > "$log"
  copy_seed_store "$CI_LINUX_TEST_SEED_STORE" /nix/store/nfb /nix/store/nfb /nix/store/input
  [ -O "$CI_LINUX_TEST_SEED_STORE/nix/var/nix/db/db.sqlite" ]
  grep -Fqx "nix copy --no-check-sigs --option auto-optimise-store false --to $CI_LINUX_TEST_SEED_STORE /nix/store/nfb /nix/store/input" "$log"
  grep -Fqx "nix path-info --store $CI_LINUX_TEST_SEED_STORE --recursive /nix/store/nfb" "$log"
  rm -rf "$scratch"
}

command="${1:-}"
shift || true
case "$command" in
  checkpoint) checkpoint_full "$@" ;;
  cleanup) cleanup_overlay "$@" ;;
  discard-temp) remove_temp_path "$@" ;;
  freeze) freeze_full "$@" ;;
  pack-full) pack_full "$@" ;;
  pack-seed) pack_seed "$@" ;;
  restore-mount) restore_mount "$@" ;;
  self-test) self_test ;;
  validate-mounted) validate_mounted "$@" ;;
  *) exit 64 ;;
esac
