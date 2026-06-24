#!/usr/bin/env bash
# Periodic fallback cleanup of leaked Namespace macOS builder state.
set -euo pipefail

: "${NSC_TOKEN_FILE:?NSC_TOKEN_FILE is required}"
: "${NAMESPACE_DARWIN_BROKER_NAME:?NAMESPACE_DARWIN_BROKER_NAME is required}"
: "${NAMESPACE_DARWIN_RUN_DIR:=/run/namespace-darwin-builder}"
: "${NAMESPACE_DARWIN_LEASE_TTL_SECONDS:=120}"
: "${NAMESPACE_DARWIN_FAILURE_LOOKBACK_SECONDS:=300}"
: "${NAMESPACE_DARWIN_BROKER_DEBUG:=false}"

export NSC_TOKEN_FILE
export HOME="$NAMESPACE_DARWIN_RUN_DIR"
export NAMESPACE_DARWIN_LOG_PREFIX="darwin-broker-reaper"

if [ -z "${NAMESPACE_DARWIN_BROKER_COMMON:-}" ]; then
  NAMESPACE_DARWIN_BROKER_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/darwin-broker-common.sh"
fi
# shellcheck source=/dev/null
. "$NAMESPACE_DARWIN_BROKER_COMMON"

handle_failure_marker() {
  local failure_timestamp

  if [ ! -f "$FAILURE_FILE" ]; then
    return 0
  fi

  failure_timestamp="$(jq -r '.timestamp // empty' < "$FAILURE_FILE" 2>/dev/null || true)"
  if ! is_recent_failure "$failure_timestamp"; then
    echo "Namespace failure marker is stale or invalid; removing without remote scan." >&2
    rm -f "$FAILURE_FILE"
    return 0
  fi

  echo "Recent namespace-mac.service failure detected; scanning for labeled orphan instances..." >&2
  if purge_labeled_instances; then
    rm -f "$FAILURE_FILE" "$RUNDIR/state.json.candidate"
    return 0
  fi

  echo "Labeled orphan cleanup failed; preserving failure marker for a later retry." >&2
  return 1
}

if systemctl is-active -q namespace-mac.service; then
  log_debug "namespace-mac.service active; skipping reaper cleanup"
  exit 0
fi

log_debug "namespace-mac.service inactive; evaluating fallback cleanup"
if [ -f "$STATE_FILE" ]; then
  if [ -f "$LEASE_FILE" ]; then
    lease_pid="$(jq -r '.pid // empty' < "$LEASE_FILE" 2>/dev/null || true)"
    lease_last_seen="$(jq -r '.last_seen // empty' < "$LEASE_FILE" 2>/dev/null || true)"
    if [ -n "${lease_pid:-}" ] && kill -0 "$lease_pid" 2>/dev/null; then
      echo "Namespace lease still owned by active PID $lease_pid; skipping reaper cleanup."
      exit 0
    fi

    if ! is_lease_stale "${lease_last_seen:-}"; then
      echo "Namespace lease is still fresh (last_seen=${lease_last_seen:-unknown}); skipping reaper cleanup."
      exit 0
    fi
  fi

  echo "Service is inactive and lease is stale/missing. Cleaning leaked state instance..." >&2
  cleanup_state_instance
fi

handle_failure_marker
