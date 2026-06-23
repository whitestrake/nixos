#!/usr/bin/env bash
# darwin-broker-ensure-instance.sh
# Purpose: ensure a Namespace-backed macOS builder instance is provisioned and SSH-ready.
# Contract:
#   - Writes/updates $RUNDIR/state.json
#   - Validates an existing reusable instance when present
#   - Creates a fresh instance when needed
# Inputs:
#   NSC_TOKEN_FILE: Namespace API token file path
#   NAMESPACE_BUILDER_KEY_PATH: SSH identity for namespace instances
#   NAMESPACE_DARWIN_BROKER_PUBLIC_KEY: Authorized key inserted into macOS users
#   NAMESPACE_DARWIN_BROKER_NAME: Instance label for host selection
#   NAMESPACE_DARWIN_RUN_DIR: Runtime directory (defaults to /run/namespace-darwin-builder)
set -euo pipefail

: "${NSC_TOKEN_FILE:?NSC_TOKEN_FILE is required}"
: "${NAMESPACE_BUILDER_KEY_PATH:?NAMESPACE_BUILDER_KEY_PATH is required}"
: "${NAMESPACE_DARWIN_BROKER_PUBLIC_KEY:?NAMESPACE_DARWIN_BROKER_PUBLIC_KEY is required}"
: "${NAMESPACE_DARWIN_BROKER_NAME:?NAMESPACE_DARWIN_BROKER_NAME is required}"
: "${NAMESPACE_DARWIN_RUN_DIR:=/run/namespace-darwin-builder}"

export NSC_TOKEN_FILE
export HOME="$NAMESPACE_DARWIN_RUN_DIR"

RUNDIR="$NAMESPACE_DARWIN_RUN_DIR"
mkdir -p "$RUNDIR"
STATE_FILE="$RUNDIR/state.json"

SSH_OPTS=(
  -n
  -i "$NAMESPACE_BUILDER_KEY_PATH"
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)

check_ssh() {
  local id="$1"
  local ssh_host="$2"
  echo "Checking SSH for existing instance $id..." >&2
  if [ -n "$ssh_host" ]; then
    echo "Checking direct SSH to $id@$ssh_host..." >&2
    if ssh "${SSH_OPTS[@]}" "$id@$ssh_host" 'echo SSH check' >/dev/null 2>&1; then
      return 0
    else
      echo "Direct SSH failed." >&2
      return 1
    fi
  fi
  return 1
}

ensure_sshd_2222() {
  local id="$1"
  local host="$2"
  echo "Ensuring custom sshd is running on port 2222 for $id..." >&2

  printf '%s\n' "$NAMESPACE_DARWIN_BROKER_PUBLIC_KEY" \
    | ssh "${SSH_OPTS[@]}" "$id@$host" \
      'mkdir -p ~/.ssh /var/root/.ssh &&
       chmod 700 ~/.ssh /var/root/.ssh &&
       tee ~/.ssh/authorized_keys >/dev/null | sudo -n tee /var/root/.ssh/authorized_keys >/dev/null &&
       chmod 600 ~/.ssh/authorized_keys &&
       sudo -n chmod 600 /var/root/.ssh/authorized_keys'

  ssh "${SSH_OPTS[@]}" "$id@$host" \
    "sudo -n ssh-keygen -A"

  ssh "${SSH_OPTS[@]}" "$id@$host" \
    "if ! sudo -n lsof -i tcp:2222 -sTCP:LISTEN -t >/dev/null 2>&1; then sudo -n /usr/sbin/sshd -p 2222 -o ListenAddress=127.0.0.1 -o PermitRootLogin=yes; fi"

  for _ in $(seq 1 10); do
    if ssh "${SSH_OPTS[@]}" "$id@$host" "nc -z localhost 2222" >/dev/null 2>&1; then
      echo "Custom sshd is responsive!" >&2
      return 0
    fi
    sleep 1
  done

  echo "Timed out waiting for custom sshd on port 2222" >&2
  return 1
}

# Reuse existing valid instance from state file if possible
if [ -f "$STATE_FILE" ]; then
  EXISTING_ID=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE" || true)
  INGRESS_DOMAIN="$(jq -r '.ingress_domain // empty' < "$STATE_FILE" || true)"
  if [ -n "$EXISTING_ID" ] && [ -n "$INGRESS_DOMAIN" ] && [ "$INGRESS_DOMAIN" != "null" ]; then
    REGION="$(printf '%s\n' "$INGRESS_DOMAIN" | cut -d. -f1)"
    SSH_HOST="ssh.$REGION.namespace.so"
    if check_ssh "$EXISTING_ID" "$SSH_HOST"; then
      echo "Reusing existing valid instance: $EXISTING_ID" >&2
      if ensure_sshd_2222 "$EXISTING_ID" "$SSH_HOST"; then
        date +%s > "$RUNDIR/last-used"
        exit 0
      fi
    fi
  fi
fi

# Find existing instance with labels
EXISTING_ID=$(
  nsc list -o json | jq -r '
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
      $lbls.broker == "'"${NAMESPACE_DARWIN_BROKER_NAME}"'"
    ) | .instance_id // .cluster_id // .id // empty
  ' | head -n 1 || true
)

if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
  nsc describe "$EXISTING_ID" -o json > "$STATE_FILE.candidate"
  INGRESS_DOMAIN="$(jq -r '.ingress_domain // empty' < "$STATE_FILE.candidate" || true)"
  if [ -z "$INGRESS_DOMAIN" ] || [ "$INGRESS_DOMAIN" = "null" ]; then
    nsc list -o json | jq --arg id "$EXISTING_ID" '.[]? | select(.instance_id == $id or .cluster_id == $id or .id == $id)' > "$STATE_FILE.candidate"
    INGRESS_DOMAIN="$(jq -r '.ingress_domain // empty' < "$STATE_FILE.candidate" || true)"
  fi
  if [ -n "$INGRESS_DOMAIN" ] && [ "$INGRESS_DOMAIN" != "null" ]; then
    REGION="$(printf '%s\n' "$INGRESS_DOMAIN" | cut -d. -f1)"
    SSH_HOST="ssh.$REGION.namespace.so"
    if check_ssh "$EXISTING_ID" "$SSH_HOST"; then
      echo "Found running instance with matching labels: $EXISTING_ID" >&2
      if ensure_sshd_2222 "$EXISTING_ID" "$SSH_HOST"; then
        mv "$STATE_FILE.candidate" "$STATE_FILE"
        date +%s > "$RUNDIR/last-used"
        exit 0
      fi
    fi
  fi
  rm -f "$STATE_FILE.candidate"
fi

echo "Creating macOS instance on Namespace.so..." >&2
INSTANCE_JSON=$(nsc create \
  --machine_type macos/arm64:6x14 \
  --bare \
  --duration 30m \
  --ssh_key <(echo "${NAMESPACE_DARWIN_BROKER_PUBLIC_KEY}") \
  --label "purpose=hci-darwin-builder" \
  --label "repo=whitestrake/nixos" \
  --label "broker=${NAMESPACE_DARWIN_BROKER_NAME}" \
  -o json)

INSTANCE_ID=$(echo "$INSTANCE_JSON" | jq -r '.instance_id // .cluster_id // .id // empty')
if [ -z "$INSTANCE_ID" ]; then
  echo "Failed to parse instance ID!" >&2
  exit 1
fi

INGRESS_DOMAIN="$(echo "$INSTANCE_JSON" | jq -r '.ingress_domain // empty')"
if [ -z "$INGRESS_DOMAIN" ] || [ "$INGRESS_DOMAIN" = "null" ]; then
  echo "Created Namespace instance has no ingress_domain; direct SSH required for builder." >&2
  nsc destroy "$INSTANCE_ID" --force || true
  exit 1
fi

REGION="$(printf '%s\n' "$INGRESS_DOMAIN" | cut -d. -f1)"
if [ -z "$REGION" ] || [ "$REGION" = "null" ]; then
  echo "Could not derive Namespace region from created instance ingress_domain: $INGRESS_DOMAIN" >&2
  nsc destroy "$INSTANCE_ID" --force || true
  exit 1
fi

SSH_HOST="ssh.$REGION.namespace.so"

# Save Namespace state immediately after create
echo "$INSTANCE_JSON" > "$STATE_FILE"
date +%s > "$RUNDIR/last-used"

# Wait for SSH to be responsive
echo "Waiting for SSH to become responsive..." >&2
for i in $(seq 1 30); do
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

if ! ensure_sshd_2222 "$INSTANCE_ID" "$SSH_HOST"; then
  exit 1
fi

# Ensure root user shell is /bin/zsh so non-interactive SSH connections source /etc/zshenv
ssh "${SSH_OPTS[@]}" "$INSTANCE_ID@$SSH_HOST" \
  "sudo -n dscl . -create /Users/root UserShell /bin/zsh" >/dev/null 2>&1 || true

# Install Nix on macOS if not present
echo "Checking for Nix on instance..." >&2
if ! ssh "${SSH_OPTS[@]}" "$INSTANCE_ID@$SSH_HOST" "command -v nix" >/dev/null 2>&1; then
  echo "Nix not found. Installing Nix..." >&2
  if ! ssh "${SSH_OPTS[@]}" "$INSTANCE_ID@$SSH_HOST" \
      "curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm" >&2; then
    echo "Nix installation failed!" >&2
    exit 1
  fi
  echo "Nix installed successfully." >&2
else
  echo "Nix is already installed." >&2
fi

# Ensure Nix binaries are available in standard PATH for non-interactive SSH
ssh "${SSH_OPTS[@]}" "$INSTANCE_ID@$SSH_HOST" \
  "sudo -n mkdir -p /usr/local/bin && sudo -n ln -sf /nix/var/nix/profiles/default/bin/nix* /usr/local/bin/" \
  >/dev/null 2>&1 || true

# Save state
echo "$INSTANCE_JSON" > "$STATE_FILE"
date +%s > "$RUNDIR/last-used"
