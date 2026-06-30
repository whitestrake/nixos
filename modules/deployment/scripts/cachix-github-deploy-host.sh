#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-whitestrake}"
host="${DEPLOY_HOST:-}"
system="${DEPLOY_SYSTEM:-}"
store_path="${DEPLOY_STORE_PATH:-}"
rollback_script="${DEPLOY_ROLLBACK_SCRIPT:-}"
deploy_plan_file="${CACHIX_DEPLOY_PLAN_FILE:-}"
force="${CACHIX_DEPLOY_FORCE:-false}"
output_dir="${CACHIX_DEPLOY_OUTPUT_DIR:-$PWD}"
deployed_pin_keep_revisions="${CACHIX_DEPLOYED_PIN_KEEP_REVISIONS:-10}"

# shellcheck source=modules/deployment/scripts/cachix-pin-functions.sh
source "${CACHIX_PIN_FUNCTIONS_SCRIPT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cachix-pin-functions.sh}"

case "$force" in
  true|false)
    ;;
  *)
    echo "ERROR: CACHIX_DEPLOY_FORCE must be true or false." >&2
    exit 1
    ;;
esac

if [ -z "$host" ]; then
  echo "ERROR: DEPLOY_HOST is empty." >&2
  exit 1
fi

if [ -n "$deploy_plan_file" ]; then
  if [ ! -r "$deploy_plan_file" ]; then
    echo "ERROR: CACHIX_DEPLOY_PLAN_FILE is not readable: $deploy_plan_file" >&2
    exit 1
  fi

  host_record="$(
    jq -c \
      --arg host "$host" \
      '.include[]? | select(.host == $host)' \
      "$deploy_plan_file"
  )"

  if [ -z "$host_record" ]; then
    echo "ERROR: deploy plan has no row for host: $host" >&2
    exit 1
  fi

  system="$(jq -r '.system // ""' <<< "$host_record")"
  store_path="$(jq -r '.storePath // ""' <<< "$host_record")"
  rollback_script="$(jq -r '.rollbackScript // ""' <<< "$host_record")"
fi

if [ -z "$system" ]; then
  echo "ERROR: DEPLOY_SYSTEM is empty." >&2
  exit 1
fi

if [[ "$store_path" != /nix/store/* ]]; then
  echo "ERROR: DEPLOY_STORE_PATH must be a /nix/store path." >&2
  exit 1
fi

if [[ "$rollback_script" != /nix/store/* ]]; then
  echo "ERROR: DEPLOY_ROLLBACK_SCRIPT must be a /nix/store path." >&2
  exit 1
fi

if ! [[ "$deployed_pin_keep_revisions" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: CACHIX_DEPLOYED_PIN_KEEP_REVISIONS must be a positive integer." >&2
  exit 1
fi

if [ -z "${CACHIX_AUTH_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_AUTH_TOKEN is empty." >&2
  exit 1
fi

if [ -z "${CACHIX_ACTIVATE_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_ACTIVATE_TOKEN is empty." >&2
  exit 1
fi

pins="$(cachix_fetch_pins "$cache_name")"
deploy_pin="deployed-host-$host"
deployed="$(cachix_pin_path "$pins" "$deploy_pin")"

if [ "$force" != "true" ] && [ "$deployed" = "$store_path" ]; then
  echo "$deploy_pin already matches $store_path; skipping $host."
  exit 0
fi

mkdir -p "$output_dir"
deploy_spec="$output_dir/deploy-$host.json"

jq -n \
  --arg host "$host" \
  --arg system "$system" \
  --arg storePath "$store_path" \
  --arg rollbackScript "$rollback_script" \
  '{
    agents: {
      ($host): $storePath
    },
    rollbackScript: {
      ($system): $rollbackScript
    }
  }' \
  > "$deploy_spec"

echo "Deploying $host:"
echo "  current deployed pin: ${deployed:-[none]}"
echo "  target store path:    $store_path"
echo "  deploy spec:          $deploy_spec"
jq . "$deploy_spec"

if ! cachix deploy activate "$deploy_spec"; then
  echo "Cachix deploy activate failed for $host. $deploy_pin was not updated." >&2
  exit 1
fi

echo "Cachix deploy activate succeeded for $host. Updating $deploy_pin."
cachix_pin_store_path "$cache_name" "$deploy_pin" "$store_path" "$deployed_pin_keep_revisions"
