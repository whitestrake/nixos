#!/usr/bin/env bash
set -euo pipefail

image_bundle="${NIX_ROOT_IMAGE_BUNDLE:-}"

run_with_timeout() {
  perl -e 'alarm shift; exec @ARGV' "$@"
}

if mount | grep -q ' on /nix '; then
  started="$SECONDS"
  detach_status=0
  run_with_timeout 120 sync \
    || echo "::warning ::sync timed out before detaching /nix."
  run_with_timeout 120 sudo hdiutil detach /nix \
    || run_with_timeout 120 sudo hdiutil detach -force /nix \
    || detach_status=$?
  duration="$((SECONDS - started))"
  if [ "$detach_status" -eq 0 ]; then
    echo "NIX_ROOT_IMAGE_DETACHED system=$ACTION_SYSTEM path=$image_bundle mountPoint=/nix durationSeconds=$duration source=post"
  else
    echo "::warning ::failed to detach /nix before post cleanup timeout."
    echo "NIX_ROOT_IMAGE_DETACH_FAILED system=$ACTION_SYSTEM path=$image_bundle mountPoint=/nix status=$detach_status durationSeconds=$duration source=post"
  fi
fi
