#!/usr/bin/env bash
# darwin-broker-init.sh
# Purpose: prepare runtime-only Namespace macOS builder state before socket activation.
#   - Generate/validate the ephemeral SSH key used for Namespace/native SSH and inner root SSH
#   - Destroy stale instances labeled as owned by this broker from a previous boot
#   - Clear stale local state only when stale remote cleanup is safe
set -euo pipefail

: "${NSC_TOKEN_FILE:?NSC_TOKEN_FILE is required}"
: "${NAMESPACE_BUILDER_KEY_PATH:?NAMESPACE_BUILDER_KEY_PATH is required}"
: "${NAMESPACE_DARWIN_BROKER_NAME:?NAMESPACE_DARWIN_BROKER_NAME is required}"
: "${NAMESPACE_DARWIN_RUN_DIR:=/run/namespace-darwin-builder}"
: "${NAMESPACE_DARWIN_BROKER_DEBUG:=false}"

export NSC_TOKEN_FILE
export HOME="$NAMESPACE_DARWIN_RUN_DIR"
export NAMESPACE_DARWIN_LOG_PREFIX="darwin-broker-init"

if [ -z "${NAMESPACE_DARWIN_BROKER_COMMON:-}" ]; then
  NAMESPACE_DARWIN_BROKER_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/darwin-broker-common.sh"
fi
# shellcheck source=/dev/null
. "$NAMESPACE_DARWIN_BROKER_COMMON"

KEY_PATH="$NAMESPACE_BUILDER_KEY_PATH"

if [ ! -r "$NSC_TOKEN_FILE" ]; then
  echo "NSC_TOKEN_FILE is missing or unreadable: $NSC_TOKEN_FILE" >&2
  exit 1
fi

mkdir -p "$RUNDIR"
chmod 700 "$RUNDIR"

generate_key() {
  rm -f "$KEY_PATH" "$KEY_PATH.pub"
  umask 077
  ssh-keygen \
    -t ed25519 \
    -N "" \
    -C "namespace-builder-${NAMESPACE_DARWIN_BROKER_NAME}" \
    -f "$KEY_PATH" \
    >/dev/null
}

refresh_public_key() {
  ssh-keygen -y -f "$KEY_PATH" > "$KEY_PATH.pub"
}

enforce_key_permissions() {
  chmod 600 "$KEY_PATH"
  refresh_public_key
  chmod 644 "$KEY_PATH.pub"
}

if [ -f "$KEY_PATH" ]; then
  chmod 600 "$KEY_PATH" 2>/dev/null || true
  if ssh-keygen -y -f "$KEY_PATH" >/dev/null 2>&1; then
    log_debug "using existing runtime SSH key at $KEY_PATH"
  else
    echo "Runtime SSH key at $KEY_PATH is invalid; regenerating." >&2
    generate_key
  fi
else
  log_debug "generating runtime SSH key at $KEY_PATH"
  generate_key
fi
enforce_key_permissions

if systemctl is-active -q namespace-mac.service; then
  echo "namespace-mac.service is active; skipping stale instance cleanup." >&2
  exit 0
fi

if purge_labeled_instances; then
  log_debug "removing stale local broker state"
  remove_all_local_state
  exit 0
fi

echo "Failed to remove stale Namespace macOS builder instances; preserving local broker state." >&2
exit 1
