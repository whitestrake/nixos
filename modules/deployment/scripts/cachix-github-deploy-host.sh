#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-whitestrake}"
host="${DEPLOY_HOST:-}"
system="${DEPLOY_SYSTEM:-}"
store_path="${DEPLOY_STORE_PATH:-}"
rollback_script="${DEPLOY_ROLLBACK_SCRIPT:-}"
force="${CACHIX_DEPLOY_FORCE:-false}"
output_dir="${CACHIX_DEPLOY_OUTPUT_DIR:-$PWD}"

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

if [ -z "${CACHIX_AUTH_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_AUTH_TOKEN is empty." >&2
  exit 1
fi

if [ -z "${CACHIX_ACTIVATE_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_ACTIVATE_TOKEN is empty." >&2
  exit 1
fi

with_retry() {
  local n=1 max=3 delay=2
  while true; do
    if "$@"; then
      break
    fi

    if [[ $n -lt $max ]]; then
      n=$((n + 1))
      echo "Command failed. Attempt $n/$max in $delay seconds:" >&2
      sleep "$delay"
      delay=$((delay * 2))
    else
      echo "Command failed after $n attempts." >&2
      return 1
    fi
  done
}

fetch_pins() {
  with_retry curl -fsS \
    -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
    "https://app.cachix.org/api/v1/cache/$cache_name/pin" \
    | jq -e 'if type == "array" then . else error("Cachix pin API did not return an array") end'
}

pin_path() {
  local pin_name="$1"
  jq -r \
    --arg name "$pin_name" \
    'map(select(.name == $name))[0].lastRevision.storePath // ""' \
    <<< "$pins"
}

pin_deployed_state() {
  local pin_name="$1"
  local path="$2"
  local payload

  case "$pin_name" in
    deployed-host-*)
      ;;
    *)
      echo "ERROR: refusing to update non-deployed pin: $pin_name" >&2
      return 1
      ;;
  esac

  payload="$(
    jq -n \
      --arg name "$pin_name" \
      --arg storePath "$path" \
      '{name: $name, storePath: $storePath, artifacts: [], keep: null}'
  )"

  with_retry curl -fsS \
    -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "https://app.cachix.org/api/v1/cache/$cache_name/pin" \
    >/dev/null
}

pins="$(fetch_pins)"
deploy_pin="deployed-host-$host"
deployed="$(pin_path "$deploy_pin")"

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
pin_deployed_state "$deploy_pin" "$store_path"
