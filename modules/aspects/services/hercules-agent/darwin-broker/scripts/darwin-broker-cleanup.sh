#!/usr/bin/env bash
# darwin-broker-cleanup.sh
# Purpose: teardown helper for namespace macOS broker lifecycle.
#   - Kill SSH tunnel if running
#   - Destroy namespace instance if state exists
#   - Remove broker state files
set -euo pipefail

: "${NSC_TOKEN_FILE:?NSC_TOKEN_FILE is required}"
: "${NAMESPACE_DARWIN_RUN_DIR:=/run/namespace-darwin-builder}"

export NSC_TOKEN_FILE
export HOME="$NAMESPACE_DARWIN_RUN_DIR"

RUNDIR="$NAMESPACE_DARWIN_RUN_DIR"
TUNNEL_PID_FILE="$RUNDIR/tunnel.pid"
STATE_FILE="$RUNDIR/state.json"
LEASE_FILE="$RUNDIR/lease.json"

# Kill the tunnel process if it exists
if [ -f "$TUNNEL_PID_FILE" ]; then
  TUNNEL_PID=$(cat "$TUNNEL_PID_FILE" 2>/dev/null || true)
  if [ -n "${TUNNEL_PID:-}" ]; then
    echo "Killing SSH tunnel PID $TUNNEL_PID..." >&2
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  fi
fi

# Destroy the Namespace instance if state exists
if [ -f "$STATE_FILE" ]; then
  INSTANCE_ID=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE" 2>/dev/null || true)
  if [ -n "$INSTANCE_ID" ]; then
    echo "Destroying Namespace instance $INSTANCE_ID..." >&2
    nsc destroy "$INSTANCE_ID" --force || true
  fi
fi

# Clean up files
rm -f "$STATE_FILE" "$TUNNEL_PID_FILE" "$RUNDIR/last-used" "$LEASE_FILE"
