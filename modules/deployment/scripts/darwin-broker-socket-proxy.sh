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
export NAMESPACE_DARWIN_LOG_PREFIX="darwin-broker-socket-proxy"

if [ -z "${NAMESPACE_DARWIN_BROKER_COMMON:-}" ]; then
  NAMESPACE_DARWIN_BROKER_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/darwin-broker-common.sh"
fi
# shellcheck source=/dev/null
. "$NAMESPACE_DARWIN_BROKER_COMMON"

mkdir -p "$RUNDIR"

UPSTREAM_PORT="$NAMESPACE_DARWIN_TUNNEL_PORT"

instance_id=""

fail() {
  local message="$1"

  echo "$message" >&2
  write_failure_marker "socket-proxy-failed" "${instance_id:-}" || true
  darwin-broker-cleanup >&2 || true
  exit 1
}

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
  fail "Failed to provision namespace instance."
fi
log_debug "namespace instance ensured"

if [ ! -s "$STATE_FILE" ]; then
  fail "Namespace state file missing or empty after ensure: $STATE_FILE"
fi

if ! instance_id=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE"); then
  fail "Failed to parse instance id from Namespace state: $STATE_FILE"
fi
if ! ingress_domain=$(jq -r '.ingress_domain // empty' < "$STATE_FILE"); then
  fail "Failed to parse ingress domain from Namespace state: $STATE_FILE"
fi
region=$(printf '%s\n' "$ingress_domain" | cut -d. -f1)

if [ -z "$instance_id" ] || [ "$instance_id" = "null" ] || \
  [ -z "$region" ] || [ "$region" = "null" ]; then
  echo "Invalid namespace state; missing instance_id or region." >&2
  echo "state=$(cat "$STATE_FILE")" >&2
  fail "Refusing to start Namespace socket proxy with invalid state."
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
  -o ExitOnForwardFailure=yes \
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
    fail "Namespace SSH tunnel process exited before readiness."
  fi

  if probe_tunnel; then
    break
  fi

  sleep 1
done

if ! probe_tunnel; then
  fail "Timed out waiting for full Namespace SSH tunnel readiness on 127.0.0.1:$UPSTREAM_PORT"
fi

write_lease "proxy-running"
log_debug "starting socket-proxyd to 127.0.0.1:$UPSTREAM_PORT"

if [ ! -x "$SYSTEMD_SOCKET_PROXYD" ]; then
  fail "systemd-socket-proxyd is missing or not executable: $SYSTEMD_SOCKET_PROXYD"
fi

exec "$SYSTEMD_SOCKET_PROXYD" \
  --connections-max=64 \
  --exit-idle-time="${NAMESPACE_DARWIN_LEASE_TTL_SECONDS}s" \
  "127.0.0.1:$UPSTREAM_PORT"
