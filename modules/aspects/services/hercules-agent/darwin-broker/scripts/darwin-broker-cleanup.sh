#!/usr/bin/env bash
# darwin-broker-cleanup.sh
# Purpose: teardown helper for namespace macOS broker lifecycle.
#   - Kill SSH tunnel if running
#   - Destroy namespace instance if state exists
#   - Remove broker state files
set -euo pipefail

: "${NSC_TOKEN_FILE:?NSC_TOKEN_FILE is required}"
: "${NAMESPACE_DARWIN_RUN_DIR:=/run/namespace-darwin-builder}"
: "${NAMESPACE_DARWIN_BROKER_DEBUG:=false}"

export NSC_TOKEN_FILE
export HOME="$NAMESPACE_DARWIN_RUN_DIR"

RUNDIR="$NAMESPACE_DARWIN_RUN_DIR"
TUNNEL_PID_FILE="$RUNDIR/tunnel.pid"
STATE_FILE="$RUNDIR/state.json"
LEASE_FILE="$RUNDIR/lease.json"
DEBUG="${NAMESPACE_DARWIN_BROKER_DEBUG:-false}"

log_debug() {
  case "$DEBUG" in
    1|true|TRUE|True|yes|YES|on|ON)
      printf '%s\n' "[darwin-broker-cleanup] $*" >&2
      ;;
  esac
}

# Kill the tunnel process if it exists
if [ -f "$TUNNEL_PID_FILE" ]; then
  log_debug "found tunnel pid file $TUNNEL_PID_FILE"
  TUNNEL_PID=$(cat "$TUNNEL_PID_FILE" 2>/dev/null || true)
  if [ -n "${TUNNEL_PID:-}" ]; then
    echo "Killing SSH tunnel PID $TUNNEL_PID..." >&2
    kill "$TUNNEL_PID" 2>/dev/null || true

    for _ in $(seq 1 20); do
      if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done

    if kill -0 "$TUNNEL_PID" 2>/dev/null; then
      echo "SSH tunnel PID $TUNNEL_PID did not exit after TERM; killing." >&2
      kill -KILL "$TUNNEL_PID" 2>/dev/null || true
    fi
  fi

  rm -f "$TUNNEL_PID_FILE"
fi

# Destroy the Namespace instance if state exists
if [ -f "$STATE_FILE" ]; then
  log_debug "found state file $STATE_FILE"
  INSTANCE_ID=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE" 2>/dev/null || true)
  if [ -n "$INSTANCE_ID" ]; then
    echo "Destroying Namespace instance $INSTANCE_ID..." >&2
    nsc destroy "$INSTANCE_ID" --force || true
  fi
fi

# Clean up files
rm -f "$STATE_FILE" "$TUNNEL_PID_FILE" "$RUNDIR/last-used" "$LEASE_FILE"
