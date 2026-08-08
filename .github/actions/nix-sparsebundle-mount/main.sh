#!/usr/bin/env bash
set -euo pipefail

image_bundle="${NIX_ROOT_IMAGE_BUNDLE:?NIX_ROOT_IMAGE_BUNDLE must be set by nix-sparsebundle-cache-restore}"
synthetic_conf=/etc/synthetic.conf

printf 'NIX_ROOT_IMAGE_BUNDLE=%s\n' "$image_bundle" >> "$GITHUB_ENV"

sudo touch "$synthetic_conf"

if grep -qE '^nix($|[[:space:]])' "$synthetic_conf"; then
  if ! grep -qx 'nix' "$synthetic_conf"; then
    echo "::error ::$synthetic_conf already defines nix differently."
    grep -nE '^nix($|[[:space:]])' "$synthetic_conf" || true
    exit 1
  fi
else
  printf 'nix\n' | sudo tee -a "$synthetic_conf" >/dev/null
fi

if ! sudo /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -B >/dev/null 2>&1; then
  sudo /System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util -t >/dev/null 2>&1 \
    || echo "apfs.util did not report successful synthetic object materialization; validating /nix directly."
fi

if [ ! -e /nix ]; then
  echo "::error ::macOS did not materialize synthetic /nix."
  sudo cat "$synthetic_conf"
  exit 1
fi

if [ -L /nix ]; then
  echo "::error ::/nix is a symlink; Nix requires /nix to be a real directory or mountpoint."
  ls -ld /nix
  exit 1
fi

if [ -d "$image_bundle" ]; then
  started="$SECONDS"
  hdiutil resize -size "$ACTION_IMAGE_SIZE" "$image_bundle"
  duration="$((SECONDS - started))"
  echo "NIX_ROOT_IMAGE_RESIZED system=$ACTION_SYSTEM path=$image_bundle size=$ACTION_IMAGE_SIZE durationSeconds=$duration"
  echo "NIX_ROOT_IMAGE_READY system=$ACTION_SYSTEM path=$image_bundle source=cache"
else
  started="$SECONDS"
  hdiutil create \
    -size "$ACTION_IMAGE_SIZE" \
    -type SPARSEBUNDLE \
    -fs 'Case-sensitive Journaled HFS+' \
    -volname NixStore \
    "$image_bundle"
  duration="$((SECONDS - started))"
  echo "NIX_ROOT_IMAGE_CREATED system=$ACTION_SYSTEM path=$image_bundle size=$ACTION_IMAGE_SIZE fs=case-sensitive-jhfs-plus durationSeconds=$duration"
fi

started="$SECONDS"
sudo hdiutil attach \
  -mountpoint /nix \
  -nobrowse \
  "$image_bundle"
duration="$((SECONDS - started))"
echo "NIX_ROOT_IMAGE_ATTACHED system=$ACTION_SYSTEM path=$image_bundle mountPoint=/nix durationSeconds=$duration"

sudo chown "$USER" /nix
chmod u+rwx /nix

size_number="${ACTION_IMAGE_SIZE%[KkMmGgTt]}"
size_suffix="${ACTION_IMAGE_SIZE#"$size_number"}"
if ! [[ "$size_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error ::unsupported sparsebundle image size: $ACTION_IMAGE_SIZE"
  exit 1
fi

case "$size_suffix" in
  "") requested_bytes="$size_number" ;;
  [Kk]) requested_bytes=$((size_number * 1024)) ;;
  [Mm]) requested_bytes=$((size_number * 1024 * 1024)) ;;
  [Gg]) requested_bytes=$((size_number * 1024 * 1024 * 1024)) ;;
  [Tt]) requested_bytes=$((size_number * 1024 * 1024 * 1024 * 1024)) ;;
  *)
    echo "::error ::unsupported sparsebundle image size: $ACTION_IMAGE_SIZE"
    exit 1
    ;;
esac

actual_bytes="$(diskutil info -plist /nix | plutil -extract TotalSize raw -)"
minimum_bytes=$((requested_bytes * 99 / 100))
if ! [[ "$actual_bytes" =~ ^[1-9][0-9]*$ ]] || [ "$actual_bytes" -lt "$minimum_bytes" ]; then
  echo "::error ::mounted sparsebundle capacity is below the requested size: actualBytes=${actual_bytes:-unknown} requestedBytes=$requested_bytes"
  exit 1
fi

echo "NIX_ROOT_IMAGE_CAPACITY_VERIFIED system=$ACTION_SYSTEM path=$image_bundle actualBytes=$actual_bytes requestedBytes=$requested_bytes"
