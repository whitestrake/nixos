#!/usr/bin/env bash
# The nixpkgs trees the Darwin lane evaluates. A hosted Mac downloads them from
# cache.nixos.org at a few hundred KB/s, so after a lock bump it spent minutes
# on them. Update Packages saves them to the Actions cache as a file:// binary
# cache, and the Darwin lane substitutes from that instead.
#   key:   cache key for the locked trees
#   paths: their store paths (computed from the lock, nothing is fetched)
set -euo pipefail
inputs=(nixpkgs-darwin nixpkgs-unstable-darwin)
case "$1" in
  key)
    jq -r '[.nodes[$ARGS.positional[]].locked.narHash] | join(" ")' --args "${inputs[@]}" < flake.lock |
      sha256sum | cut -c1-16
    ;;
  paths)
    nix flake archive --dry-run --json | jq -r '.inputs[$ARGS.positional[]].path' --args "${inputs[@]}"
    ;;
esac
