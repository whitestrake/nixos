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
