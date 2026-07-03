#!/usr/bin/env bash
set -euo pipefail

image="${NIX_ROOT_IMAGE:?NIX_ROOT_IMAGE must be set by nix-ext4-cache-restore}"
archive="${NIX_ROOT_IMAGE_ARCHIVE:-$image.zst}"

{
  printf 'NIX_ROOT_IMAGE=%s\n' "$image"
  printf 'NIX_ROOT_IMAGE_ARCHIVE=%s\n' "$archive"
} >> "$GITHUB_ENV"

for tool in zstd mkfs.ext4 truncate mount; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "::error ::$tool is required for ext4 Nix image cache lanes."
    exit 1
  fi
done

if [ -s "$archive" ]; then
  started="$SECONDS"
  rm -f "$image"
  zstd --sparse -d -f "$archive" -o "$image"
  duration="$((SECONDS - started))"
  echo "NIX_ROOT_IMAGE_DECOMPRESSED system=$ACTION_SYSTEM path=$image archive=$archive durationSeconds=$duration"
else
  started="$SECONDS"
  rm -f "$image" "$archive"
  truncate -s "$ACTION_IMAGE_SIZE" "$image"
  mkfs.ext4 -F -m 0 "$image"
  duration="$((SECONDS - started))"
  echo "NIX_ROOT_IMAGE_CREATED system=$ACTION_SYSTEM path=$image size=$ACTION_IMAGE_SIZE fs=ext4 durationSeconds=$duration"
fi

ls -lh "$image" || true
du -h "$image" || true
du -h --apparent-size "$image" || true

sudo mkdir -p /nix
if mountpoint -q /nix; then
  echo "::error ::/nix is already a mountpoint."
  findmnt /nix || true
  exit 1
fi
if [ -n "$(sudo find /nix -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  echo "::error ::/nix exists and is not empty before mounting the image."
  sudo ls -la /nix
  exit 1
fi

started="$SECONDS"
if sudo mount -o loop,discard "$image" /nix; then
  mount_options=loop,discard
else
  echo "NIX_ROOT_IMAGE_MOUNT_DISCARD_UNSUPPORTED system=$ACTION_SYSTEM fallingBackTo=loop"
  sudo mount -o loop "$image" /nix
  mount_options=loop
fi
duration="$((SECONDS - started))"
echo "NIX_ROOT_IMAGE_MOUNTED system=$ACTION_SYSTEM path=$image mountPoint=/nix options=$mount_options durationSeconds=$duration"

sudo chown "$USER" /nix
chmod u+rwx /nix
df -h /nix
