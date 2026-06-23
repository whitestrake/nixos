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

export NSC_TOKEN_FILE
export HOME="$NAMESPACE_DARWIN_RUN_DIR"

RUNDIR="$NAMESPACE_DARWIN_RUN_DIR"
mkdir -p "$RUNDIR"

STATE_FILE="$RUNDIR/state.json"
LEASE_FILE="$RUNDIR/lease.json"
TUNNEL_PID_FILE="$RUNDIR/tunnel.pid"
UPSTREAM_PORT=22023

cleanup_on_failure() {
  darwin-broker-cleanup >&2 || true
}
trap cleanup_on_failure ERR

STATE_UUID="$(date +%s)-$$-${RANDOM}"

write_lease() {
  local state="$1"
  local now
  now="$(date +%s)"
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
if ! darwin-broker-ensure-instance 3<&- >&2; then
  echo "Failed to provision namespace instance." >&2
  exit 1
fi

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

# Wait until local tunnel port is responsive
for _ in $(seq 1 100); do
  if nc -z 127.0.0.1 "$UPSTREAM_PORT"; then
    break
  fi
  sleep 0.1
done

if ! nc -z 127.0.0.1 "$UPSTREAM_PORT"; then
  echo "Timed out waiting for Namespace SSH tunnel on local port $UPSTREAM_PORT" >&2
  kill "$TUNNEL_PID" 2>/dev/null || true
  wait "$TUNNEL_PID" 2>/dev/null || true
  exit 1
fi

write_lease "proxy-running"

# Exec systemd-socket-proxyd
exec "$SYSTEMD_SOCKET_PROXYD" \
  --connections-max=64 \
  --exit-idle-time=20s \
  "127.0.0.1:$UPSTREAM_PORT"
