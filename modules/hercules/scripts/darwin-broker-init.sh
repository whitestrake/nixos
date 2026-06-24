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

RUNDIR="$NAMESPACE_DARWIN_RUN_DIR"
KEY_PATH="$NAMESPACE_BUILDER_KEY_PATH"
DEBUG="${NAMESPACE_DARWIN_BROKER_DEBUG:-false}"

log_debug() {
  case "$DEBUG" in
    1|true|TRUE|True|yes|YES|on|ON)
      printf '%s\n' "[darwin-broker-init] $*" >&2
      ;;
  esac
}

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
  chmod 600 "$KEY_PATH"
  chmod 644 "$KEY_PATH.pub" 2>/dev/null || true
}

if [ -f "$KEY_PATH" ]; then
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

if systemctl is-active -q namespace-mac.service; then
  echo "namespace-mac.service is active; skipping stale instance cleanup." >&2
  exit 0
fi

matching_instances="$(
  nsc list --all -o json | jq -r '
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
  '
)"

log_debug "removing stale local broker state"
rm -f \
  "$RUNDIR/state.json" \
  "$RUNDIR/state.json.candidate" \
  "$RUNDIR/lease.json" \
  "$RUNDIR/last-used" \
  "$RUNDIR/tunnel.pid"

if [ -z "$matching_instances" ]; then
  log_debug "no stale Namespace macOS builder instances found"
  exit 0
fi

while IFS= read -r instance_id; do
  [ -n "$instance_id" ] || continue
  echo "Destroying stale Namespace macOS builder instance $instance_id..." >&2
  nsc destroy "$instance_id" --force
done <<< "$matching_instances"
