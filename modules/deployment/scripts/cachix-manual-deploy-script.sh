#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-whitestrake}"
hosts_raw="${CACHIX_DEPLOY_HOSTS:-}"
force="${CACHIX_DEPLOY_FORCE:-false}"
deploy_spec_pin="${CACHIX_DEPLOY_SPEC_PIN:-built-deploy-spec}"
binary_cache_url="${CACHIX_BINARY_CACHE_URL:-https://$cache_name.cachix.org}"
deploy_spec_file="${CACHIX_DEPLOY_SPEC_FILE:-}"
output_dir="${CACHIX_DEPLOY_OUTPUT_DIR:-$PWD}"

case "$force" in
  true|false)
    ;;
  *)
    echo "ERROR: CACHIX_DEPLOY_FORCE must be true or false." >&2
    exit 1
    ;;
esac

if [ -z "${CACHIX_AUTH_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_AUTH_TOKEN is empty." >&2
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

resolve_deploy_spec_file() {
  if [ -n "$deploy_spec_file" ]; then
    if [ ! -f "$deploy_spec_file" ]; then
      echo "ERROR: CACHIX_DEPLOY_SPEC_FILE does not exist: $deploy_spec_file" >&2
      exit 1
    fi
    return
  fi

  local deploy_spec_path
  deploy_spec_path="$(pin_path "$deploy_spec_pin")"

  if [ -z "$deploy_spec_path" ]; then
    echo "ERROR: Cachix pin $deploy_spec_pin was not found." >&2
    echo "HCI must publish the manual deploy spec before this workflow can deploy." >&2
    exit 1
  fi

  echo "Fetching deploy spec from Cachix:"
  echo "  $deploy_spec_pin -> $deploy_spec_path"
  with_retry nix copy --from "$binary_cache_url" "$deploy_spec_path"

  deploy_spec_file="$deploy_spec_path/deploy.json"
  if [ ! -f "$deploy_spec_file" ]; then
    echo "ERROR: deploy spec path does not contain deploy.json: $deploy_spec_path" >&2
    exit 1
  fi
}

validate_deploy_spec() {
  if ! jq -e '
    type == "object"
    and (.agents | type == "object")
    and (.rollbackScript | type == "object")
  ' "$deploy_spec_file" >/dev/null; then
    echo "ERROR: deploy spec must contain object fields agents and rollbackScript." >&2
    exit 1
  fi
}

trimmed_hosts="$(
  jq -rn --arg hosts "$hosts_raw" '$hosts | gsub("^\\s+|\\s+$"; "")'
)"

pins="$(fetch_pins)"
resolve_deploy_spec_file
validate_deploy_spec

changed_info_json="$(
  jq -c \
    --argjson pins "$pins" \
    '
      def pinPath($name):
        (($pins[]? | select(.name == $name) | .lastRevision.storePath) // "");

      .agents
      | to_entries
      | sort_by(.key)
      | map(
          pinPath("deployed-host-" + .key) as $deployed
          | {
              host: .key,
              current: .value,
              deployed: $deployed,
              changed: ($deployed != .value)
            }
        )
    ' "$deploy_spec_file"
)"

print_changed_table() {
  local rows
  rows="$(jq -r '.[] | select(.changed) | [.host, (.deployed // ""), .current] | @tsv' <<< "$changed_info_json")"

  if [ -z "$rows" ]; then
    echo "No deployable hosts differ from deployed pin state."
    return
  fi

  printf '%-24s %-48s %s\n' "host" "deployed" "built"
  printf '%-24s %-48s %s\n' "----" "--------" "-----"
  while IFS=$'\t' read -r host deployed current; do
    printf '%-24s %-48s %s\n' "$host" "${deployed:-[none]}" "$current"
  done <<< "$rows"
}

if [ -z "$trimmed_hosts" ]; then
  echo "Manual Cachix deploy preview"
  echo "Downloaded deploy spec:"
  jq . "$deploy_spec_file"
  echo ""
  echo "Hosts where deployed-host-* differs from built state:"
  print_changed_table
  exit 0
fi

all_hosts_json="$(jq -c '.agents | keys | sort' "$deploy_spec_file")"

if [ "$trimmed_hosts" = "all" ]; then
  requested_hosts_json="$all_hosts_json"
else
  requested_hosts_json="$(
    jq -cn \
      --arg hosts "$trimmed_hosts" \
      '$hosts | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
  )"

  if jq -e 'length == 0' <<< "$requested_hosts_json" >/dev/null; then
    echo "ERROR: hosts input did not contain any host names." >&2
    exit 1
  fi

  unknown_hosts_json="$(
    jq -cn \
      --argjson requested "$requested_hosts_json" \
      --argjson available "$all_hosts_json" \
      '$requested | map(. as $host | select(($available | index($host)) | not))'
  )"

  if ! jq -e 'length == 0' <<< "$unknown_hosts_json" >/dev/null; then
    while IFS= read -r host; do
      echo "ERROR: unknown or non-deployable host: $host" >&2
    done < <(jq -r '.[]' <<< "$unknown_hosts_json")
    exit 1
  fi
fi

selected_hosts_json="$(
  jq -cn \
    --arg force "$force" \
    --argjson requested "$requested_hosts_json" \
    --argjson changed "$changed_info_json" \
    '
      def changed($host):
        (($changed[] | select(.host == $host) | .changed) // false);

      if $force == "true" then
        $requested
      else
        $requested | map(select(changed(.)))
      end
    '
)"

selected_count="$(jq -r 'length' <<< "$selected_hosts_json")"

echo "Manual Cachix deploy selection:"
echo "  hosts input: $trimmed_hosts"
echo "  force:       $force"
echo "  selected:    $(jq -r 'if length == 0 then "[none]" else join(", ") end' <<< "$selected_hosts_json")"

if [ "$selected_count" -eq 0 ]; then
  echo "No selected hosts require deployment."
  exit 0
fi

if [ -z "${CACHIX_ACTIVATE_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_ACTIVATE_TOKEN is empty for mutating deployment." >&2
  exit 1
fi

mkdir -p "$output_dir"
filtered_deploy_spec="$output_dir/filtered-deploy.json"

jq \
  --argjson selected "$selected_hosts_json" \
  '{
    agents: (.agents | with_entries(select(.key as $host | $selected | index($host)))),
    rollbackScript: .rollbackScript
  }' \
  "$deploy_spec_file" > "$filtered_deploy_spec"

echo "Filtered deploy spec:"
jq . "$filtered_deploy_spec"

echo "Activating Cachix Deploy for $selected_count host(s): $(jq -r 'join(", ")' <<< "$selected_hosts_json")"
if ! cachix deploy activate "$filtered_deploy_spec"; then
  echo "Cachix deploy activate failed. Deployed pins were not updated." >&2
  exit 1
fi

echo "Cachix deploy activate succeeded. Updating deployed pins."
while IFS=$'\t' read -r host store_path; do
  pin_name="deployed-host-$host"
  echo "  $pin_name -> $store_path"
  pin_deployed_state "$pin_name" "$store_path"
done < <(jq -r '.agents | to_entries[] | [.key, .value] | @tsv' "$filtered_deploy_spec")
