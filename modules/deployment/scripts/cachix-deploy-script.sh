#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-}"
deploy_items="${DEPLOY_ITEMS_JSON:-[]}"
deploy_spec_path="${DEPLOY_SPEC_PATH:-}"
deploy_spec_pin="${DEPLOY_SPEC_PIN:-built-deploy-spec}"
binary_cache_url="${CACHIX_BINARY_CACHE_URL:-https://$cache_name.cachix.org}"

if [ -z "$cache_name" ]; then
  echo "ERROR: CACHIX_CACHE_NAME is empty." >&2
  exit 1
fi

if [ -z "${CACHIX_AUTH_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_AUTH_TOKEN is empty." >&2
  exit 1
fi

if [ -z "$deploy_spec_path" ]; then
  echo "ERROR: DEPLOY_SPEC_PATH is empty." >&2
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

validate_deploy_items() {
  local index=0 errors=0 item host system store_path deploy_pin rollback

  while IFS= read -r item; do
    host="$(jq -r '.host // empty' <<< "$item")"
    system="$(jq -r '.system // empty' <<< "$item")"
    store_path="$(jq -r '.storePath // empty' <<< "$item")"
    deploy_pin="$(jq -r '.deployPin // empty' <<< "$item")"
    rollback="$(jq -r '.rollbackScript // empty' <<< "$item")"

    validate_required_field "deploy" "$index" "host" "$host" || errors=$((errors + 1))
    validate_required_field "deploy" "$index" "system" "$system" || errors=$((errors + 1))
    validate_required_field "deploy" "$index" "storePath" "$store_path" || errors=$((errors + 1))
    validate_required_field "deploy" "$index" "deployPin" "$deploy_pin" || errors=$((errors + 1))
    validate_required_field "deploy" "$index" "rollbackScript" "$rollback" || errors=$((errors + 1))

    case "$deploy_pin" in
      deployed-host-*)
        ;;
      *)
        echo "ERROR: deploy item at index $index has non-deployed pin: $deploy_pin" >&2
        errors=$((errors + 1))
        ;;
    esac

    index=$((index + 1))
  done < <(printf '%s\n' "$deploy_items" | jq -c '.[]')

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
    built-deploy-spec|deployed-host-*)
      ;;
    *)
      echo "ERROR: refusing to update unexpected pin: $pin_name" >&2
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
  echo "HCI should build selected deployment outputs and upload them to Cachix before deployment effects run." >&2
  return 1
}

pin_built_deploy_spec() {
  local previous_built rollback

  previous_built="$(pin_path "$deploy_spec_pin")"

  if [ "$previous_built" = "$deploy_spec_path" ]; then
    echo "Built deploy spec already pinned:"
    echo "  $deploy_spec_pin -> $previous_built"
    return 0
  fi

  echo "Built deploy spec differs:"
  echo "  previous: ${previous_built:-[none]}"
  echo "  current:  $deploy_spec_path"

  while IFS= read -r rollback; do
    [ -n "$rollback" ] || continue
    ensure_cached_path "manual deploy spec" "rollback script" "$rollback" || return 1
  done < <(printf '%s\n' "$deploy_items" | jq -r '[.[].rollbackScript] | unique[]')

  ensure_cached_path "deploy spec" "deploy spec" "$deploy_spec_path" || return 1

  echo "Pinning built deploy spec: $deploy_spec_pin -> $deploy_spec_path"
  if ! pin_state "$deploy_spec_pin" "$deploy_spec_path"; then
    echo "Failed to pin deploy spec to Cachix." >&2
    return 1
  fi

  pins="$(fetch_pins)"
}

probe_cachix_agent() {
  local host="$1"
  local code

  if [ -z "${CACHIX_PERSONAL_TOKEN:-}" ]; then
    echo "No Cachix personal token available for agent probe; skipping deploy for $host." >&2
    return 1
  fi

  code="$(
    curl -sS \
      --retry 3 \
      --retry-delay 2 \
      --retry-all-errors \
      -o /dev/null \
      -w "%{http_code}" \
      -H "Authorization: Bearer $CACHIX_PERSONAL_TOKEN" \
      "https://cachix.org/api/v1/deploy/agent/$cache_name/$host" \
      || echo "000"
  )"

  if [ "$code" = "200" ]; then
    return 0
  fi

  echo "Cachix Deploy agent for '$host' is not registered/reachable (HTTP $code)." >&2
  return 1
}

deploy_one() {
  local item="$1"
  local host system store_path deploy_pin rollback deployed deploy_spec

  host="$(jq -r '.host' <<< "$item")"
  system="$(jq -r '.system' <<< "$item")"
  store_path="$(jq -r '.storePath' <<< "$item")"
  deploy_pin="$(jq -r '.deployPin' <<< "$item")"
  rollback="$(jq -r '.rollbackScript' <<< "$item")"

  deployed="$(pin_path "$deploy_pin")"

  if [ "$deployed" = "$store_path" ]; then
    echo "Already deployed for $host:"
    echo "  $deploy_pin -> $deployed"
    return 0
  fi

  echo "Deployed state differs for $host:"
  echo "  deployed: ${deployed:-[none]}"
  echo "  current:  $store_path"

  if [ -z "${CACHIX_ACTIVATE_TOKEN:-}" ]; then
    echo "ERROR: CACHIX_ACTIVATE_TOKEN is empty for mutating deployment." >&2
    return 1
  fi

  deploy_spec="$tmpdir/deploy-$host.json"

  jq -n \
    --arg agent "$host" \
    --arg path "$store_path" \
    --arg sys "$system" \
    --arg rollback "$rollback" \
    '{"agents": {($agent): $path}, "rollbackScript": {($sys): $rollback}}' \
    > "$deploy_spec"

  ensure_cached_path "$host" "system closure" "$store_path" || return 1
  ensure_cached_path "$host" "rollback script" "$rollback" || return 1

  if ! probe_cachix_agent "$host"; then
    echo "Deployment failed for $host because its Cachix Deploy agent is unavailable." >&2
    return 1
  fi

  echo "Generated deploy spec for $host:"
  cat "$deploy_spec"

  echo "Activating Cachix Deploy for $host..."
  if ! cachix deploy activate "$deploy_spec"; then
    echo "Cachix deploy activate failed for $host." >&2
    return 1
  fi

  echo "Deployment succeeded for $host. Pinning deployed state:"
  echo "  $deploy_pin -> $store_path"
  if ! pin_state "$deploy_pin" "$store_path"; then
    echo "Failed to pin deployed state for $host." >&2
    return 1
  fi
}

validate_json_array DEPLOY_ITEMS_JSON "$deploy_items"
validate_deploy_items

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

pins="$(fetch_pins)"

echo "============================================================"
echo "Deploy Spec Pinning"
echo "============================================================"

if ! pin_built_deploy_spec; then
  echo "Deploy spec pinning failed. Skipping deploy phase." >&2
  exit 1
fi

if printf '%s\n' "$deploy_items" | jq -e 'type == "array" and length == 0' >/dev/null; then
  echo "No Cachix Deploy targets found. Deploy spec pinning is complete."
  exit 0
fi

echo ""
echo "============================================================"
echo "Cachix Deployment"
echo "============================================================"

phase_b_errors=0
declare -A deploy_pids=()
declare -A deploy_logs=()

while IFS= read -r item; do
  host="$(jq -r '.host // "unknown"' <<< "$item")"
  log="$tmpdir/deploy-$host.log"
  deploy_logs["$host"]="$log"

  (
    deploy_one "$item"
  ) >"$log" 2>&1 &

  deploy_pids["$host"]=$!
done < <(printf '%s\n' "$deploy_items" | jq -c '.[]')

for host in "${!deploy_pids[@]}"; do
  pid="${deploy_pids[$host]}"
  log="${deploy_logs[$host]}"

  if wait "$pid"; then
    echo "Deployment job succeeded for $host."
  else
    rc="$?"
    echo "Deployment job failed for $host with exit code $rc." >&2
    phase_b_errors=$((phase_b_errors + 1))
  fi

  echo "----- deploy log: $host -----"
  cat "$log"
done

if [ "$phase_b_errors" -gt 0 ]; then
  echo "Deployment completed with $phase_b_errors errors." >&2
  exit 1
fi
