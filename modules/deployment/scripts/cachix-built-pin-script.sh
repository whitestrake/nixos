#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-}"
build_items="${BUILD_ITEMS_JSON:-[]}"
binary_cache_url="${CACHIX_BINARY_CACHE_URL:-https://$cache_name.cachix.org}"

if [ -z "$cache_name" ]; then
  echo "ERROR: CACHIX_CACHE_NAME is empty." >&2
  exit 1
fi

if [ -z "${CACHIX_AUTH_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_AUTH_TOKEN is empty." >&2
  exit 1
fi

validate_json_array() {
  local var_name="$1"
  local value="$2"

  if ! printf '%s\n' "$value" | jq -e 'type == "array"' >/dev/null; then
    echo "ERROR: $var_name must be a JSON array." >&2
    exit 1
  fi
}

validate_required_field() {
  local kind="$1"
  local index="$2"
  local field="$3"
  local value="$4"

  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "ERROR: malformed $kind item at index $index has no $field." >&2
    return 1
  fi
}

validate_build_items() {
  local index=0 errors=0 item host store_path build_pin

  while IFS= read -r item; do
    host="$(jq -r '.host // empty' <<< "$item")"
    store_path="$(jq -r '.storePath // empty' <<< "$item")"
    build_pin="$(jq -r '.buildPin // empty' <<< "$item")"

    validate_required_field "build" "$index" "host" "$host" || errors=$((errors + 1))
    validate_required_field "build" "$index" "storePath" "$store_path" || errors=$((errors + 1))
    validate_required_field "build" "$index" "buildPin" "$build_pin" || errors=$((errors + 1))

    case "$build_pin" in
      built-host-*)
        ;;
      *)
        echo "ERROR: build item at index $index has non-built pin: $build_pin" >&2
        errors=$((errors + 1))
        ;;
    esac

    index=$((index + 1))
  done < <(printf '%s\n' "$build_items" | jq -c '.[]')

  if [ "$errors" -gt 0 ]; then
    exit 1
  fi
}

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

pin_state() {
  local pin_name="$1"
  local store_path="$2"
  local payload

  case "$pin_name" in
    built-host-*)
      ;;
    *)
      echo "ERROR: refusing to update non-built pin: $pin_name" >&2
      return 1
      ;;
  esac

  payload="$(
    jq -n \
      --arg name "$pin_name" \
      --arg storePath "$store_path" \
      '{name: $name, storePath: $storePath, artifacts: [], keep: null}'
  )"

  with_retry curl -fsS \
    -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "https://app.cachix.org/api/v1/cache/$cache_name/pin" \
    >/dev/null
}

path_available_in_cache() {
  local store_path="$1"
  local store_name store_hash cache_base

  store_name="${store_path#/nix/store/}"
  if [ "$store_name" = "$store_path" ]; then
    return 1
  fi

  store_hash="${store_name%%-*}"
  if [ -z "$store_hash" ] || [ "$store_hash" = "$store_name" ]; then
    return 1
  fi

  cache_base="${binary_cache_url%/}"
  curl -fsS -o /dev/null "$cache_base/$store_hash.narinfo" >/dev/null 2>&1
}

path_available_locally() {
  local store_path="$1"

  [ -e "$store_path" ]
}

path_available_in_cache_with_retry() {
  local store_path="$1"
  local n=1 max=3 delay=2

  while true; do
    if path_available_in_cache "$store_path"; then
      return 0
    fi

    if [[ $n -lt $max ]]; then
      n=$((n + 1))
      sleep "$delay"
      delay=$((delay * 2))
    else
      return 1
    fi
  done
}

ensure_cached_path() {
  local host="$1"
  local description="$2"
  local store_path="$3"

  if path_available_in_cache "$store_path"; then
    echo "Cachix already has $description for $host: $store_path"
    return 0
  fi

  if path_available_locally "$store_path"; then
    echo "Pushing $description for $host to Cachix: $store_path"
    if with_retry cachix push "$cache_name" "$store_path"; then
      return 0
    fi

    echo "ERROR: failed to push $description for $host to Cachix: $store_path" >&2
    return 1
  fi

  if path_available_in_cache_with_retry "$store_path"; then
    echo "Cachix now has $description for $host: $store_path"
    return 0
  fi

  echo "ERROR: expected $description for $host is neither in Cachix nor local to the effect runner: $store_path" >&2
  echo "HCI should build selected host outputs and upload them to Cachix before built-state pinning runs." >&2
  return 1
}

validate_json_array BUILD_ITEMS_JSON "$build_items"
validate_build_items

if printf '%s\n' "$build_items" | jq -e 'type == "array" and length == 0' >/dev/null; then
  echo "No built-state pin targets found."
  exit 0
fi

pins="$(fetch_pins)"
errors=0

echo "============================================================"
echo "Built-State Pinning"
echo "============================================================"

while IFS= read -r item; do
  host="$(jq -r '.host' <<< "$item")"
  store_path="$(jq -r '.storePath' <<< "$item")"
  build_pin="$(jq -r '.buildPin' <<< "$item")"

  echo "--- target: $host ---"

  previous_built="$(pin_path "$build_pin")"

  if [ "$previous_built" = "$store_path" ]; then
    echo "Built state already pinned for $host."
    continue
  fi

  echo "Built state differs for $host:"
  echo "  previous: ${previous_built:-[none]}"
  echo "  current:  $store_path"

  echo "Ensuring system closure is present in Cachix..."
  if ! ensure_cached_path "$host" "system closure" "$store_path"; then
    errors=$((errors + 1))
    continue
  fi

  echo "Pinning built state: $build_pin -> $store_path"
  if ! pin_state "$build_pin" "$store_path"; then
    echo "Failed to pin $host to Cachix." >&2
    errors=$((errors + 1))
    continue
  fi

  pins="$(fetch_pins)" || {
    echo "Failed to fetch pins after pinning $host." >&2
    errors=$((errors + 1))
    continue
  }
done < <(printf '%s\n' "$build_items" | jq -c '.[]')

if [ "$errors" -gt 0 ]; then
  echo "Built-state pinning completed with $errors errors." >&2
  exit 1
fi
