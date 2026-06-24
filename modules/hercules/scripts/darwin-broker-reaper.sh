#!/usr/bin/env bash
# darwin-broker-reaper.sh
# Purpose: periodic fallback cleanup of leaked namespace instance state.
# Contract:
#   - only acts when namespace-mac.service is inactive
#   - destroys state/instance only if lease is absent or stale
set -euo pipefail

: "${NSC_TOKEN_FILE:?NSC_TOKEN_FILE is required}"
: "${NAMESPACE_DARWIN_BROKER_NAME:?NAMESPACE_DARWIN_BROKER_NAME is required}"
: "${NAMESPACE_DARWIN_RUN_DIR:=/run/namespace-darwin-builder}"
: "${NAMESPACE_DARWIN_LEASE_TTL_SECONDS:=120}"
: "${NAMESPACE_DARWIN_FAILURE_LOOKBACK_SECONDS:=300}"
: "${NAMESPACE_DARWIN_BROKER_DEBUG:=false}"

export NSC_TOKEN_FILE
export HOME="$NAMESPACE_DARWIN_RUN_DIR"

RUNDIR="$NAMESPACE_DARWIN_RUN_DIR"
STATE_FILE="$RUNDIR/state.json"
LEASE_FILE="$RUNDIR/lease.json"
FAILURE_FILE="$RUNDIR/failure.json"
DEBUG="${NAMESPACE_DARWIN_BROKER_DEBUG:-false}"

log_debug() {
  case "$DEBUG" in
    1|true|TRUE|True|yes|YES|on|ON)
      printf '%s\n' "[darwin-broker-reaper] $*" >&2
      ;;
  esac
}

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

is_recent_failure() {
  local timestamp="$1"
  local now age

  if [ -z "${timestamp}" ] || [ "$timestamp" = "null" ]; then
    return 1
  fi
  if ! [[ "$timestamp" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  now="$(date +%s)"
  age=$(( now - timestamp ))
  [ "$age" -le "$NAMESPACE_DARWIN_FAILURE_LOOKBACK_SECONDS" ]
}

purge_labeled_instances() {
  local matching_instances failed

  matching_instances="$(
    nsc list --all -o json | jq -r --arg broker "$NAMESPACE_DARWIN_BROKER_NAME" '
      .[]? |
      ( if .labels | type == "array" then
          reduce .labels[] as $l ({}; .[$l.name] = $l.value)
        elif .labels | type == "object" then
          .labels
        elif .label | type == "array" then
          reduce .label[] as $l ({}; .[$l.name] = $l.value)
        else
          {}
        end
      ) as $lbls |
      select(
        $lbls.purpose == "hci-darwin-builder" and
        $lbls.repo == "whitestrake/nixos" and
        $lbls.broker == $broker
      ) | .instance_id // .cluster_id // .id // empty
    '
  )"

  if [ -z "$matching_instances" ]; then
    log_debug "no labeled Namespace macOS builder instances found after failure"
    return 0
  fi

  failed=0
  while IFS= read -r instance_id; do
    [ -n "$instance_id" ] || continue
    echo "Destroying Namespace macOS builder instance left after service failure: $instance_id..." >&2
    nsc destroy "$instance_id" --force || failed=1
  done <<< "$matching_instances"

  return "$failed"
}

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
  purge_labeled_instances
  rm -f "$FAILURE_FILE" "$RUNDIR/state.json.candidate"
}

if systemctl is-active -q namespace-mac.service; then
  log_debug "namespace-mac.service active; skipping reaper cleanup"
  exit 0
fi

log_debug "namespace-mac.service inactive; evaluating fallback cleanup"
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

handle_failure_marker
