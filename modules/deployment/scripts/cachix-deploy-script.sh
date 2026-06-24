#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-}"
hci_mode="${HCI_MODE:-dry}"
deployment_enabled="${DEPLOYMENT_ENABLED:-false}"
build_items="${BUILD_ITEMS_JSON:-[]}"
deploy_items="${DEPLOY_ITEMS_JSON:-[]}"
deploy_spec_path="${DEPLOY_SPEC_PATH:-}"
deploy_spec_pin="${DEPLOY_SPEC_PIN:-built-deploy-spec}"
binary_cache_url="${CACHIX_BINARY_CACHE_URL:-https://$cache_name.cachix.org}"

# Mode validation
case "$hci_mode" in
  dry|production)
    ;;
  *)
    echo "ERROR: invalid HCI_MODE: $hci_mode" >&2
    exit 1
    ;;
esac

# Cache name validation
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

validate_build_items() {
  local index=0 errors=0 item host store_path build_pin

  while IFS= read -r item; do
    host="$(jq -r '.host // empty' <<< "$item")"
    store_path="$(jq -r '.storePath // empty' <<< "$item")"
    build_pin="$(jq -r '.buildPin // empty' <<< "$item")"

    validate_required_field "build" "$index" "host" "$host" || errors=$((errors + 1))
    validate_required_field "build" "$index" "storePath" "$store_path" || errors=$((errors + 1))
    validate_required_field "build" "$index" "buildPin" "$build_pin" || errors=$((errors + 1))
    index=$((index + 1))
  done < <(printf '%s\n' "$build_items" | jq -c '.[]')

  if [ "$errors" -gt 0 ]; then
    exit 1
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
    index=$((index + 1))
  done < <(printf '%s\n' "$deploy_items" | jq -c '.[]')

  if [ "$errors" -gt 0 ]; then
    exit 1
  fi
}

validate_json_array BUILD_ITEMS_JSON "$build_items"
validate_json_array DEPLOY_ITEMS_JSON "$deploy_items"
validate_build_items
validate_deploy_items

# Context logging
echo "HCI mode: $hci_mode"
echo "Deployment enabled: $deployment_enabled"
hci_branch="${HCI_BRANCH:-}"
echo "HCI branch: ${hci_branch:-[unknown]}"

is_dry_run() {
  [ "$hci_mode" = "dry" ]
}

with_retry() {
  local n=1 max=3 delay=2
  while true; do
    if "$@"; then
      break
    else
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed. Attempt $n/$max in $delay seconds:" >&2
        sleep $delay
        delay=$((delay * 2))
      else
        echo "Command failed after $n attempts." >&2
        return 1
      fi
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
  local store_path="$2"
  local payload

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

  nix path-info --store "$binary_cache_url" "$store_path" >/dev/null 2>&1
}

path_available_locally() {
  local store_path="$1"

  nix path-info "$store_path" >/dev/null 2>&1
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
  echo "HCI should build selected host outputs and upload them to Cachix before production deployment effects run." >&2
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

  if is_dry_run; then
    while IFS= read -r rollback; do
      [ -n "$rollback" ] || continue
      echo "[dry-run] would push rollback script for manual deploy spec: $rollback"
    done < <(printf '%s\n' "$deploy_items" | jq -r '[.[].rollbackScript] | unique[]')
    echo "[dry-run] would push deploy spec: $deploy_spec_path"
    echo "[dry-run] would pin deploy spec: $deploy_spec_pin -> $deploy_spec_path"
    return 0
  fi

  while IFS= read -r rollback; do
    [ -n "$rollback" ] || continue

    ensure_cached_path "manual deploy spec" "rollback script" "$rollback" || return 1
  done < <(printf '%s\n' "$deploy_items" | jq -r '[.[].rollbackScript] | unique[]')

  ensure_cached_path "deploy spec" "deploy spec" "$deploy_spec_path" || return 1

  echo "Pinning built deploy spec: $deploy_spec_pin -> $deploy_spec_path"
  if ! with_retry cachix pin "$cache_name" "$deploy_spec_pin" "$deploy_spec_path"; then
    echo "Failed to pin deploy spec to cachix." >&2
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

  # deploy item validation here
  if [ -z "$host" ] || [ "$host" = "null" ]; then
    echo "ERROR: malformed deploy item with missing host: $item" >&2
    return 1
  fi

  if [ -z "$store_path" ] || [ "$store_path" = "null" ]; then
    echo "ERROR: malformed deploy item for $host has no storePath." >&2
    return 1
  fi

  if [ -z "$deploy_pin" ] || [ "$deploy_pin" = "null" ]; then
    echo "ERROR: malformed deploy item for $host has no deployPin." >&2
    return 1
  fi

  if [ -z "$rollback" ] || [ "$rollback" = "null" ]; then
    echo "ERROR: deployable host $host has no rollback script. Refusing to continue." >&2
    return 1
  fi

  deployed="$(pin_path "$deploy_pin")"

  if [ "$deployed" = "$store_path" ]; then
    echo "Already deployed for $host:"
    echo "  $deploy_pin -> $deployed"
    return 0
  fi

  echo "Deployed state differs for $host:"
  echo "  deployed: ${deployed:-[none]}"
  echo "  current:  $store_path"

  deploy_spec="$tmpdir/deploy-$host.json"

  jq -n \
    --arg agent "$host" \
    --arg path "$store_path" \
    --arg sys "$system" \
    --arg rollback "$rollback" \
    '{"agents": {($agent): $path}, "rollbackScript": {($sys): $rollback}}' \
    > "$deploy_spec"

  if is_dry_run; then
    echo "[dry-run] would push rollback script for $host: $rollback"
    echo "[dry-run] would probe Cachix Deploy agent for $host: skipped in dry mode"
    echo "[dry-run] would activate Cachix Deploy for $host with spec:"
    cat "$deploy_spec"
    echo "[dry-run] would pin deployed state: $deploy_pin -> $store_path"
    return 0
  fi

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
  if ! pin_deployed_state "$deploy_pin" "$store_path"; then
    echo "Failed to pin deployed state for $host." >&2
    return 1
  fi
}

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

if printf '%s\n' "$build_items" | jq -e 'type == "array" and length == 0' >/dev/null; then
  echo "No build/pin targets found. Nothing to pin or deploy."
  exit 0
fi

pins="$(fetch_pins)"

echo "============================================================"
echo "PHASE A: Built-State Pinning"
echo "============================================================"

phase_a_errors=0

while read -r item; do
  host="$(jq -r '.host' <<< "$item")"
  store_path="$(jq -r '.storePath' <<< "$item")"
  build_pin="$(jq -r '.buildPin' <<< "$item")"

  echo "--- target: $host ---"

  if [ -z "$host" ] || [ "$host" = "null" ]; then
    echo "ERROR: malformed build item with missing host." >&2
    phase_a_errors=$((phase_a_errors + 1))
    continue
  fi

  if [ -z "$store_path" ] || [ "$store_path" = "null" ]; then
    echo "ERROR: malformed build item for $host has no storePath." >&2
    phase_a_errors=$((phase_a_errors + 1))
    continue
  fi

  previous_built="$(pin_path "$build_pin")"

  if [ "$previous_built" = "$store_path" ]; then
    echo "Built state already pinned for $host."
  else
    echo "Built state differs for $host:"
    echo "  previous: ${previous_built:-[none]}"
    echo "  current:  $store_path"

    if is_dry_run; then
      echo "[dry-run] would push system closure for $host: $store_path"
      echo "[dry-run] would pin built state: $build_pin -> $store_path"
    else
      echo "Ensuring system closure is present in Cachix..."
      if ! ensure_cached_path "$host" "system closure" "$store_path"; then
        phase_a_errors=$((phase_a_errors + 1))
        continue
      fi

      echo "Pinning built state: $build_pin -> $store_path"
      if ! with_retry cachix pin "$cache_name" "$build_pin" "$store_path"; then
        echo "Failed to pin $host to cachix." >&2
        phase_a_errors=$((phase_a_errors + 1))
        continue
      fi

      pins="$(fetch_pins)" || {
        echo "Failed to fetch pins after pinning $host." >&2
        phase_a_errors=$((phase_a_errors + 1))
        continue
      }
    fi
  fi
done < <(printf '%s\n' "$build_items" | jq -c '.[]')

if [ "$phase_a_errors" -gt 0 ]; then
  echo "Phase A completed with $phase_a_errors errors. Skipping deploy phase." >&2
  exit 1
fi

echo ""
echo "============================================================"
echo "PHASE A.5: Deploy Spec Pinning"
echo "============================================================"

if ! pin_built_deploy_spec; then
  echo "Deploy spec pinning failed. Skipping deploy phase." >&2
  exit 1
fi

if [ "$deployment_enabled" != "true" ]; then
  if is_dry_run; then
    echo "HCI dry mode: deployment mutations disabled."
    echo "Dry-run deploy candidate evaluation only; no Cachix pins or host state will change."
  else
    echo "Deployment disabled for this branch/mode; deployment skipped after built-state pins."
    exit 0
  fi
fi

if printf '%s\n' "$deploy_items" | jq -e 'type == "array" and length == 0' >/dev/null; then
  echo "No Cachix Deploy targets found. Built-state pins are complete."
  exit 0
fi

echo ""
echo "============================================================"
echo "PHASE B: Cachix Deployment"
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
  echo "Phase B completed with $phase_b_errors errors." >&2
  exit 1
fi
