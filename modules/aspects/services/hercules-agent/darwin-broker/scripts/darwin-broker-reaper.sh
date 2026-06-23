#!/usr/bin/env bash
# darwin-broker-reaper.sh
# Purpose: periodic fallback cleanup of leaked namespace instance state.
# Contract:
#   - only acts when namespace-mac.service is inactive
#   - destroys state/instance only if lease is absent or stale
set -euo pipefail

: "${NSC_TOKEN_FILE:?NSC_TOKEN_FILE is required}"
: "${NAMESPACE_DARWIN_RUN_DIR:=/run/namespace-darwin-builder}"
: "${NAMESPACE_DARWIN_LEASE_TTL_SECONDS:=120}"

export NSC_TOKEN_FILE
export HOME="$NAMESPACE_DARWIN_RUN_DIR"

RUNDIR="$NAMESPACE_DARWIN_RUN_DIR"
STATE_FILE="$RUNDIR/state.json"
LEASE_FILE="$RUNDIR/lease.json"

is_lease_stale() {
  local last_seen="$1"
  local now

  if [ -z "${last_seen}" ] || [ "$last_seen" = "null" ]; then
    return 0
  fi
  if ! [[ "$last_seen" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  now="$(date +%s)"
  [ $(( now - last_seen )) -gt "$NAMESPACE_DARWIN_LEASE_TTL_SECONDS" ]
}

if ! systemctl is-active -q namespace-mac.service; then
  if [ -f "$STATE_FILE" ]; then
    instance_id=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE" 2>/dev/null || true)

    if [ -f "$LEASE_FILE" ]; then
      lease_pid=$(jq -r '.pid // empty' < "$LEASE_FILE" 2>/dev/null || true)
      lease_last_seen=$(jq -r '.last_seen // empty' < "$LEASE_FILE" 2>/dev/null || true)
      if [ -n "${lease_pid:-}" ] && kill -0 "$lease_pid" 2>/dev/null; then
        echo "Namespace lease still owned by active PID $lease_pid; skipping reaper cleanup."
        exit 0
      fi

      if ! is_lease_stale "${lease_last_seen:-}"; then
        echo "Namespace lease is still fresh (last_seen=${lease_last_seen:-unknown}); skipping reaper cleanup."
        exit 0
      fi
    fi

    if [ -n "${instance_id:-}" ]; then
      echo "Service is inactive and lease is stale/missing. Destroying leaked instance $instance_id..." >&2
      nsc destroy "$instance_id" --force || true
    fi
    rm -f "$STATE_FILE" "$RUNDIR/tunnel.pid" "$RUNDIR/last-used" "$LEASE_FILE"
  fi
fi
