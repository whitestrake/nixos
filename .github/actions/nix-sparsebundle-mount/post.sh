#!/usr/bin/env bash
set -euo pipefail

image_bundle="${NIX_ROOT_IMAGE_BUNDLE:-}"

if mount | grep -q ' on /nix '; then
  started="$SECONDS"
  sync
  sudo hdiutil detach /nix || sudo hdiutil detach -force /nix
  duration="$((SECONDS - started))"
  echo "NIX_ROOT_IMAGE_DETACHED system=$ACTION_SYSTEM path=$image_bundle mountPoint=/nix durationSeconds=$duration source=post"
fi
