#!/usr/bin/env bash
set -euo pipefail

image="${NIX_ROOT_IMAGE:-}"

if mountpoint -q /nix; then
  sync
  started="$SECONDS"
  sudo umount /nix || sudo umount -l /nix
  duration="$((SECONDS - started))"
  echo "NIX_ROOT_IMAGE_UNMOUNTED system=$ACTION_SYSTEM path=$image mountPoint=/nix durationSeconds=$duration source=post"
fi
