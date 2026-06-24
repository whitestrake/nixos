#!/usr/bin/env bash
# Teardown helper for the Namespace macOS broker lifecycle.
set -euo pipefail

: "${NSC_TOKEN_FILE:?NSC_TOKEN_FILE is required}"
: "${NAMESPACE_DARWIN_RUN_DIR:=/run/namespace-darwin-builder}"
: "${NAMESPACE_DARWIN_BROKER_DEBUG:=false}"

export NSC_TOKEN_FILE
export HOME="$NAMESPACE_DARWIN_RUN_DIR"
export NAMESPACE_DARWIN_LOG_PREFIX="darwin-broker-cleanup"

if [ -z "${NAMESPACE_DARWIN_BROKER_COMMON:-}" ]; then
  NAMESPACE_DARWIN_BROKER_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/darwin-broker-common.sh"
fi
# shellcheck source=/dev/null
. "$NAMESPACE_DARWIN_BROKER_COMMON"

cleanup_state_instance
