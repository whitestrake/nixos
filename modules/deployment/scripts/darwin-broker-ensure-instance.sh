#!/usr/bin/env bash
# Ensure a Namespace-backed macOS builder instance is provisioned and guest-bootstrapped.
set -euo pipefail

: "${NSC_TOKEN_FILE:?NSC_TOKEN_FILE is required}"
: "${NAMESPACE_BUILDER_KEY_PATH:?NAMESPACE_BUILDER_KEY_PATH is required}"
: "${NAMESPACE_DARWIN_BROKER_NAME:?NAMESPACE_DARWIN_BROKER_NAME is required}"
: "${NAMESPACE_DARWIN_GUEST_BOOTSTRAP:?NAMESPACE_DARWIN_GUEST_BOOTSTRAP is required}"
: "${NAMESPACE_DARWIN_RUN_DIR:=/run/namespace-darwin-builder}"
: "${NAMESPACE_DARWIN_BROKER_DEBUG:=false}"

export NSC_TOKEN_FILE
export HOME="$NAMESPACE_DARWIN_RUN_DIR"
export NAMESPACE_DARWIN_LOG_PREFIX="darwin-broker-ensure-instance"

if [ -z "${NAMESPACE_DARWIN_BROKER_COMMON:-}" ]; then
  NAMESPACE_DARWIN_BROKER_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/darwin-broker-common.sh"
fi
# shellcheck source=/dev/null
. "$NAMESPACE_DARWIN_BROKER_COMMON"

mkdir -p "$RUNDIR"
BROKER_PUBLIC_KEY="${NAMESPACE_DARWIN_BROKER_PUBLIC_KEY:-}"

validate_runtime_inputs() {
  if [ ! -r "$NSC_TOKEN_FILE" ]; then
    echo "NSC_TOKEN_FILE is missing or unreadable: $NSC_TOKEN_FILE" >&2
    exit 1
  fi

  if [ ! -r "$NAMESPACE_BUILDER_KEY_PATH" ]; then
    echo "NAMESPACE_BUILDER_KEY_PATH is missing or unreadable: $NAMESPACE_BUILDER_KEY_PATH" >&2
    exit 1
  fi

  if [ ! -r "$NAMESPACE_DARWIN_GUEST_BOOTSTRAP" ]; then
    echo "NAMESPACE_DARWIN_GUEST_BOOTSTRAP is missing or unreadable: $NAMESPACE_DARWIN_GUEST_BOOTSTRAP" >&2
    exit 1
  fi

  if ! SSH_BUILDER_PUBLIC_KEY="$(ssh-keygen -y -f "$NAMESPACE_BUILDER_KEY_PATH" 2>/dev/null)"; then
    echo "NAMESPACE_BUILDER_KEY_PATH does not contain a valid private key: $NAMESPACE_BUILDER_KEY_PATH" >&2
    exit 1
  fi

  if [ -n "$BROKER_PUBLIC_KEY" ]; then
    if ! printf '%s\n' "$BROKER_PUBLIC_KEY" | ssh-keygen -l -f /dev/stdin >/dev/null 2>&1; then
      echo "NAMESPACE_DARWIN_BROKER_PUBLIC_KEY is invalid." >&2
      exit 1
    fi
  else
    BROKER_PUBLIC_KEY="$SSH_BUILDER_PUBLIC_KEY"
  fi

  if ! printf '%s\n' "$BROKER_PUBLIC_KEY" | ssh-keygen -l -f /dev/stdin >/dev/null 2>&1; then
    echo "Resolved builder public key is invalid; cannot proceed with nsc create." >&2
    exit 1
  fi
}

validate_runtime_inputs

SSH_BASE_OPTS=(
  -i "$NAMESPACE_BUILDER_KEY_PATH"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o ConnectionAttempts=1
)

SSH_OPTS=(
  -n
  "${SSH_BASE_OPTS[@]}"
)

SSH_STDIN_OPTS=(
  "${SSH_BASE_OPTS[@]}"
)

check_ssh() {
  local id="$1"
  local ssh_host="$2"
  local ssh_check_output

  if [ -z "$ssh_host" ]; then
    log_debug "ssh_host empty; skipping SSH check"
    return 1
  fi

  log_debug "checking SSH for instance $id on $ssh_host"
  if ssh_check_output="$(ssh "${SSH_OPTS[@]}" "$id@$ssh_host" 'echo SSH check' 2>&1)"; then
    log_debug "direct SSH succeeded for $id@$ssh_host"
    return 0
  fi

  echo "Direct SSH check failed for ${id}@${ssh_host}. Output:" >&2
  echo "$ssh_check_output" >&2
  return 1
}

run_guest_bootstrap() {
  local id="$1"
  local host="$2"
  local public_key_b64 bootstrap_output

  public_key_b64="$(printf '%s\n' "$BROKER_PUBLIC_KEY" | base64 | tr -d '\n')"

  log_debug "uploading guest bootstrap payload to $id@$host"
  if ! bootstrap_output="$(
    # The bootstrap key is intentionally expanded on the broker before upload.
    # shellcheck disable=SC2029
    ssh "${SSH_STDIN_OPTS[@]}" "$id@$host" \
      "cat > /tmp/darwin-guest-bootstrap.sh &&
       chmod 700 /tmp/darwin-guest-bootstrap.sh &&
       sudo -n /bin/bash /tmp/darwin-guest-bootstrap.sh '$public_key_b64'" \
      < "$NAMESPACE_DARWIN_GUEST_BOOTSTRAP" 2>&1
  )"; then
    echo "Guest bootstrap failed on $id@$host." >&2
    echo "$bootstrap_output" >&2
    return 1
  fi

  echo "$bootstrap_output" >&2
  if ! grep -q '^darwin-guest-bootstrap ok' <<< "$bootstrap_output"; then
    echo "Guest bootstrap on $id@$host did not emit the expected success marker." >&2
    return 1
  fi

  if ! ssh "${SSH_OPTS[@]}" "$id@$host" "nc -z localhost 2222" >/dev/null 2>&1; then
    echo "Guest bootstrap completed, but custom sshd is not reachable on localhost:2222." >&2
    return 1
  fi
}

cleanup_existing_state_for_replacement() {
  local reason="$1"

  echo "Existing Namespace state cannot be reused: $reason" >&2
  echo "Cleaning existing Namespace state before creating a replacement..." >&2
  if cleanup_state_instance; then
    return 0
  fi

  echo "Failed to clean existing Namespace state; refusing to create a replacement instance." >&2
  exit 1
}

state_region() {
  local ingress_domain="$1"
  printf '%s\n' "$ingress_domain" | cut -d. -f1
}

if [ -f "$STATE_FILE" ]; then
  log_debug "found existing state file $STATE_FILE"
  EXISTING_ID="$(state_instance_id)"
  INGRESS_DOMAIN="$(jq -r '.ingress_domain // empty' < "$STATE_FILE" 2>/dev/null || true)"
  if [ -n "$EXISTING_ID" ] && [ -n "$INGRESS_DOMAIN" ] && [ "$INGRESS_DOMAIN" != "null" ]; then
    REGION="$(state_region "$INGRESS_DOMAIN")"
    SSH_HOST="ssh.$REGION.namespace.so"
    log_debug "checking existing state instance=$EXISTING_ID region=$REGION"
    if check_ssh "$EXISTING_ID" "$SSH_HOST"; then
      echo "Reusing existing valid instance: $EXISTING_ID" >&2
      if run_guest_bootstrap "$EXISTING_ID" "$SSH_HOST"; then
        date +%s > "$RUNDIR/last-used"
        exit 0
      fi
      cleanup_existing_state_for_replacement "guest bootstrap failed for $EXISTING_ID"
    else
      cleanup_existing_state_for_replacement "direct SSH failed for $EXISTING_ID"
    fi
  else
    cleanup_existing_state_for_replacement "state is missing instance id or ingress domain"
  fi
fi

echo "Creating macOS instance on Namespace.so..." >&2
log_debug "no reusable instance found; creating new instance"
if ! INSTANCE_JSON="$(nsc create \
  --machine_type macos/arm64:6x14 \
  --bare \
  --duration 30m \
  --ssh_key <(echo "$BROKER_PUBLIC_KEY") \
  --label "purpose=hci-darwin-builder" \
  --label "repo=whitestrake/nixos" \
  --label "broker=${NAMESPACE_DARWIN_BROKER_NAME}" \
  -o json 2>&1)"
then
  echo "nsc create failed while provisioning macOS instance." >&2
  echo "$INSTANCE_JSON" >&2
  exit 1
fi

INSTANCE_ID="$(printf '%s\n' "$INSTANCE_JSON" | jq -r '.instance_id // .cluster_id // .id // empty')"
if [ -z "$INSTANCE_ID" ]; then
  echo "Failed to parse instance ID!" >&2
  exit 1
fi

INGRESS_DOMAIN="$(printf '%s\n' "$INSTANCE_JSON" | jq -r '.ingress_domain // empty')"
if [ -z "$INGRESS_DOMAIN" ] || [ "$INGRESS_DOMAIN" = "null" ]; then
  echo "Created Namespace instance has no ingress_domain; direct SSH required for builder." >&2
  nsc destroy "$INSTANCE_ID" --force || true
  exit 1
fi

REGION="$(state_region "$INGRESS_DOMAIN")"
if [ -z "$REGION" ] || [ "$REGION" = "null" ]; then
  echo "Could not derive Namespace region from created instance ingress_domain: $INGRESS_DOMAIN" >&2
  nsc destroy "$INSTANCE_ID" --force || true
  exit 1
fi

SSH_HOST="ssh.$REGION.namespace.so"

printf '%s\n' "$INSTANCE_JSON" > "$STATE_FILE"
date +%s > "$RUNDIR/last-used"

echo "Waiting for SSH to become responsive..." >&2
for i in $(seq 1 30); do
  log_debug "SSH readiness wait attempt $i for $INSTANCE_ID on $SSH_HOST"
  if check_ssh "$INSTANCE_ID" "$SSH_HOST"; then
    echo "SSH is responsive!" >&2
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "Timed out waiting for SSH response." >&2
    exit 1
  fi
  sleep 2
done

if ! run_guest_bootstrap "$INSTANCE_ID" "$SSH_HOST"; then
  echo "Guest bootstrap failed for newly created instance $INSTANCE_ID; cleaning up." >&2
  if cleanup_state_instance; then
    exit 1
  fi
  echo "Failed to clean newly created Namespace instance $INSTANCE_ID after bootstrap failure." >&2
  exit 1
fi

printf '%s\n' "$INSTANCE_JSON" > "$STATE_FILE"
date +%s > "$RUNDIR/last-used"
