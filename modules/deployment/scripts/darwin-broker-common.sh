#!/usr/bin/env bash
# Shared helpers for the Namespace macOS builder broker lifecycle.

: "${NAMESPACE_DARWIN_RUN_DIR:=/run/namespace-darwin-builder}"
: "${NAMESPACE_DARWIN_TUNNEL_PORT:=22023}"
: "${NAMESPACE_DARWIN_BROKER_DEBUG:=false}"

RUNDIR="$NAMESPACE_DARWIN_RUN_DIR"
STATE_FILE="$RUNDIR/state.json"
LEASE_FILE="$RUNDIR/lease.json"
TUNNEL_PID_FILE="$RUNDIR/tunnel.pid"
FAILURE_FILE="$RUNDIR/failure.json"
DEBUG="${NAMESPACE_DARWIN_BROKER_DEBUG:-false}"

log_debug() {
  case "$DEBUG" in
    1|true|TRUE|True|yes|YES|on|ON)
      printf '%s\n' "[${NAMESPACE_DARWIN_LOG_PREFIX:-darwin-broker}] $*" >&2
      ;;
  esac
}

state_instance_id() {
  if [ ! -f "$STATE_FILE" ]; then
    return 0
  fi
  jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE" 2>/dev/null || true
}

write_failure_marker() {
  local reason="${1:-unknown}"
  local instance_id="${2:-}"
  local now tmp

  if [ -z "$instance_id" ]; then
    instance_id="$(state_instance_id)"
  fi

  mkdir -p "$RUNDIR"
  now="$(date +%s)"
  tmp="$FAILURE_FILE.$$"
  umask 077
  jq -n \
    --argjson timestamp "$now" \
    --argjson pid "$$" \
    --arg reason "$reason" \
    --arg instance_id "$instance_id" \
    '{
      timestamp: $timestamp,
      pid: $pid,
      reason: $reason
    } + (if $instance_id == "" then {} else {instance_id: $instance_id} end)' \
    > "$tmp"
  mv "$tmp" "$FAILURE_FILE"
}

remove_local_state_files() {
  rm -f \
    "$STATE_FILE" \
    "$RUNDIR/state.json.candidate" \
    "$LEASE_FILE" \
    "$RUNDIR/last-used" \
    "$TUNNEL_PID_FILE"
}

remove_all_local_state() {
  remove_local_state_files
  rm -f "$FAILURE_FILE"
}

tunnel_pid_matches_expected_command() {
  local pid="$1"
  local cmdline

  if [ ! -r "/proc/$pid/cmdline" ]; then
    return 0
  fi

  cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
  case "$cmdline" in
    *ssh*127.0.0.1:"$NAMESPACE_DARWIN_TUNNEL_PORT":localhost:2222*)
      return 0
      ;;
    *)
      echo "Refusing to kill PID $pid from $TUNNEL_PID_FILE; command line does not match expected Namespace SSH tunnel." >&2
      echo "cmdline=$cmdline" >&2
      return 1
      ;;
  esac
}

kill_tunnel_from_pidfile() {
  local pid

  if [ ! -f "$TUNNEL_PID_FILE" ]; then
    return 0
  fi

  log_debug "found tunnel pid file $TUNNEL_PID_FILE"
  pid="$(cat "$TUNNEL_PID_FILE" 2>/dev/null || true)"
  if [ -z "${pid:-}" ]; then
    rm -f "$TUNNEL_PID_FILE"
    return 0
  fi

  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    echo "Ignoring non-numeric Namespace tunnel PID '$pid'." >&2
    rm -f "$TUNNEL_PID_FILE"
    return 0
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$TUNNEL_PID_FILE"
    return 0
  fi

  if ! tunnel_pid_matches_expected_command "$pid"; then
    rm -f "$TUNNEL_PID_FILE"
    return 0
  fi

  echo "Killing SSH tunnel PID $pid..." >&2
  kill "$pid" 2>/dev/null || true

  for _ in $(seq 1 20); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  if kill -0 "$pid" 2>/dev/null; then
    echo "SSH tunnel PID $pid did not exit after TERM; killing." >&2
    kill -KILL "$pid" 2>/dev/null || true
  fi

  rm -f "$TUNNEL_PID_FILE"
}

destroy_state_instance() {
  local instance_id

  if [ ! -f "$STATE_FILE" ]; then
    return 0
  fi

  log_debug "found state file $STATE_FILE"
  instance_id="$(state_instance_id)"
  if [ -z "$instance_id" ]; then
    echo "Namespace state file has no instance id; removing local state only." >&2
    return 0
  fi

  echo "Destroying Namespace instance $instance_id..." >&2
  if ! nsc destroy "$instance_id" --force; then
    echo "Failed to destroy Namespace instance $instance_id; preserving state for reaper retry." >&2
    write_failure_marker "destroy-state-failed" "$instance_id" || true
    return 1
  fi
}

cleanup_state_instance() {
  local had_state=0

  if [ -f "$STATE_FILE" ]; then
    had_state=1
  fi

  kill_tunnel_from_pidfile

  if [ "$had_state" -eq 0 ]; then
    remove_local_state_files
    return 0
  fi

  if destroy_state_instance; then
    remove_all_local_state
    return 0
  fi
  return 1
}

list_labeled_instances() {
  : "${NAMESPACE_DARWIN_BROKER_NAME:?NAMESPACE_DARWIN_BROKER_NAME is required}"

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
}

purge_labeled_instances() {
  local matching_instances failed

  if ! matching_instances="$(list_labeled_instances)"; then
    echo "Failed to list labeled Namespace macOS builder instances." >&2
    return 1
  fi

  if [ -z "$matching_instances" ]; then
    log_debug "no labeled Namespace macOS builder instances found"
    return 0
  fi

  failed=0
  while IFS= read -r instance_id; do
    [ -n "$instance_id" ] || continue
    echo "Destroying labeled Namespace macOS builder instance $instance_id..." >&2
    nsc destroy "$instance_id" --force || failed=1
  done <<< "$matching_instances"

  return "$failed"
}

is_lease_stale() {
  local last_seen="$1"
  local ttl="${NAMESPACE_DARWIN_LEASE_TTL_SECONDS:-120}"
  local now

  if [ -z "${last_seen}" ] || [ "$last_seen" = "null" ]; then
    return 0
  fi
  if ! [[ "$last_seen" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  now="$(date +%s)"
  [ $(( now - last_seen )) -gt "$ttl" ]
}

is_recent_failure() {
  local timestamp="$1"
  local lookback="${NAMESPACE_DARWIN_FAILURE_LOOKBACK_SECONDS:-300}"
  local now age

  if [ -z "${timestamp}" ] || [ "$timestamp" = "null" ]; then
    return 1
  fi
  if ! [[ "$timestamp" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  now="$(date +%s)"
  age=$(( now - timestamp ))
  [ "$age" -le "$lookback" ]
}
