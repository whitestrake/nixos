#!/usr/bin/env bash
# darwin-broker-socket-proxy.sh
# Purpose: provision/refresh a Namespace-backed builder and expose it via systemd socket activation.
# Flow:
#   1) Ensure/reuse instance
#   2) Open local SSH tunnel from 127.0.0.1:22023 -> instance:2222
#   3) Exec systemd-socket-proxyd forwarding 127.0.0.1:22022 to local tunnel
set -euo pipefail

: "${NSC_TOKEN_FILE:?NSC_TOKEN_FILE is required}"
: "${NAMESPACE_BUILDER_KEY_PATH:?NAMESPACE_BUILDER_KEY_PATH is required}"
: "${SYSTEMD_SOCKET_PROXYD:?SYSTEMD_SOCKET_PROXYD is required}"
: "${NAMESPACE_DARWIN_RUN_DIR:=/run/namespace-darwin-builder}"
: "${NAMESPACE_DARWIN_LEASE_TTL_SECONDS:=120}"
: "${NAMESPACE_DARWIN_BROKER_DEBUG:=false}"

export NSC_TOKEN_FILE
export HOME="$NAMESPACE_DARWIN_RUN_DIR"

RUNDIR="$NAMESPACE_DARWIN_RUN_DIR"
mkdir -p "$RUNDIR"

STATE_FILE="$RUNDIR/state.json"
LEASE_FILE="$RUNDIR/lease.json"
TUNNEL_PID_FILE="$RUNDIR/tunnel.pid"
FAILURE_FILE="$RUNDIR/failure.json"
UPSTREAM_PORT=22023
DEBUG="${NAMESPACE_DARWIN_BROKER_DEBUG:-false}"

log_debug() {
  case "$DEBUG" in
    1|true|TRUE|True|yes|YES|on|ON)
      printf '%s\n' "[darwin-broker-socket-proxy] $*" >&2
      ;;
  esac
}

write_failure_marker() {
  local now marker_instance_id tmp

  now="$(date +%s)"
  marker_instance_id="${instance_id:-}"
  if [ -z "$marker_instance_id" ] && [ -f "$STATE_FILE" ]; then
    marker_instance_id="$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE" 2>/dev/null || true)"
  fi

  tmp="$FAILURE_FILE.$$"
  umask 077
  jq -n \
    --argjson timestamp "$now" \
    --argjson pid "$$" \
    --arg instance_id "$marker_instance_id" \
    '{
      timestamp: $timestamp,
      pid: $pid
    } + (if $instance_id == "" then {} else {instance_id: $instance_id} end)' \
    > "$tmp"
  mv "$tmp" "$FAILURE_FILE"
}

cleanup_on_failure() {
  log_debug "running cleanup_on_failure"
  write_failure_marker || true
  darwin-broker-cleanup >&2 || true
}
trap cleanup_on_failure ERR

STATE_UUID="$(date +%s)-$$-${RANDOM}"

write_lease() {
  local state="$1"
  local now
  now="$(date +%s)"
  log_debug "writing lease state=$state instance=$instance_id pid=$$ started_at=$started_at"
  cat > "$LEASE_FILE" <<EOF
{
  "lease_id": "${STATE_UUID}",
  "instance_id": "${instance_id}",
  "pid": $$,
  "state": "${state}",
  "started_at": ${started_at},
  "last_seen": ${now}
}
EOF
}

# Provision instance (run with fd 3 closed to avoid inheriting socket FD)
log_debug "ensuring namespace instance"
if ! darwin-broker-ensure-instance 3<&- >&2; then
  echo "Failed to provision namespace instance." >&2
  exit 1
fi
log_debug "namespace instance ensured"

if [ ! -s "$STATE_FILE" ]; then
  echo "Namespace state file missing or empty after ensure: $STATE_FILE" >&2
  exit 1
fi

instance_id=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE")
ingress_domain=$(jq -r '.ingress_domain // empty' < "$STATE_FILE")
region=$(printf '%s\n' "$ingress_domain" | cut -d. -f1)

if [ -z "$instance_id" ] || [ "$instance_id" = "null" ] || \
  [ -z "$region" ] || [ "$region" = "null" ]; then
  echo "Invalid namespace state; missing instance_id or region." >&2
  echo "state=$(cat "$STATE_FILE")" >&2
  exit 1
fi

ssh_host="ssh.$region.namespace.so"
started_at="$(date +%s)"

write_lease "starting"

# Start local SSH tunnel
log_debug "starting tunnel to $ssh_host -> 127.0.0.1:$UPSTREAM_PORT"
ssh -nNT \
  -i "$NAMESPACE_BUILDER_KEY_PATH" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=10 \
  -o ServerAliveCountMax=3 \
  -L "127.0.0.1:$UPSTREAM_PORT:localhost:2222" \
  "$instance_id@$ssh_host" \
  3<&- &
TUNNEL_PID=$!
echo "$TUNNEL_PID" > "$TUNNEL_PID_FILE"

probe_tunnel() {
  ssh -n \
    -i "$NAMESPACE_BUILDER_KEY_PATH" \
    -p "$UPSTREAM_PORT" \
    -o HostName=127.0.0.1 \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    root@127.0.0.1 \
    'echo tunnel-ready' >/dev/null 2>&1
}

for i in $(seq 1 60); do
  log_debug "waiting for full tunnel SSH readiness (${i}/60)"

  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "Namespace SSH tunnel process exited before readiness." >&2
    exit 1
  fi

  if probe_tunnel; then
    break
  fi

  sleep 1
done

if ! probe_tunnel; then
  echo "Timed out waiting for full Namespace SSH tunnel readiness on 127.0.0.1:$UPSTREAM_PORT" >&2
  kill "$TUNNEL_PID" 2>/dev/null || true
  exit 1
fi

write_lease "proxy-running"
log_debug "starting socket-proxyd to 127.0.0.1:$UPSTREAM_PORT"

# Exec systemd-socket-proxyd
exec "$SYSTEMD_SOCKET_PROXYD" \
  --connections-max=64 \
  --exit-idle-time=20s \
  "127.0.0.1:$UPSTREAM_PORT"
