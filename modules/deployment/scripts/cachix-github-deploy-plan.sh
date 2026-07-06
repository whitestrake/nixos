#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-whitestrake}"
rev="${CACHIX_DEPLOY_REV:-${GITHUB_SHA:-}}"
hosts_raw="${CACHIX_DEPLOY_HOSTS:-}"
force="${CACHIX_DEPLOY_FORCE:-false}"
event_name="${GITHUB_EVENT_NAME:-}"
output_dir="${CACHIX_DEPLOY_OUTPUT_DIR:-$PWD}"

# shellcheck source=modules/deployment/scripts/cachix-pin-functions.sh
source "${CACHIX_PIN_FUNCTIONS_SCRIPT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cachix-pin-functions.sh}"

if [ -z "$rev" ]; then
  echo "ERROR: CACHIX_DEPLOY_REV or GITHUB_SHA must be set." >&2
  exit 1
fi

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

write_output() {
  local name="$1"
  local value="$2"

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
  fi
}

trimmed_hosts="$(
  jq -rn --arg hosts "$hosts_raw" '$hosts | gsub("^\\s+|\\s+$"; "")'
)"

preview=false
if [ "$event_name" = "workflow_dispatch" ] && [ -z "$trimmed_hosts" ]; then
  preview=true
fi

if [ -z "$trimmed_hosts" ]; then
  trimmed_hosts="all"
fi

mkdir -p "$output_dir"

deployables="$(
  nix eval --accept-flake-config --json .#deployment.deployables
)"

if ! jq -e '
  type == "object"
  and length > 0
  and all(
    to_entries[];
    (.key | type == "string" and length > 0)
    and (.value | type == "object")
    and (.value.system | type == "string" and length > 0)
    and (.value.storePath | type == "string" and startswith("/nix/store/"))
    and (.value.rollbackScript | type == "string" and startswith("/nix/store/"))
    and (.value.deployPin | type == "string" and startswith("deployed-host-"))
  )
' <<< "$deployables" >/dev/null; then
  echo "ERROR: .#deployment.deployables is malformed." >&2
  jq . <<< "$deployables" >&2 || true
  exit 1
fi

available_hosts_json="$(jq -c 'keys | sort' <<< "$deployables")"

if [ "$trimmed_hosts" = "all" ]; then
  requested_hosts_json="$available_hosts_json"
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
      --argjson available "$available_hosts_json" \
      '$requested | map(. as $host | select(($available | index($host)) | not))'
  )"

  if ! jq -e 'length == 0' <<< "$unknown_hosts_json" >/dev/null; then
    while IFS= read -r host; do
      echo "ERROR: unknown or non-deployable host: $host" >&2
    done < <(jq -r '.[]' <<< "$unknown_hosts_json")
    exit 1
  fi
fi

proofs_json="$(
  jq -c \
    --arg rev "$rev" \
    '
      [
        to_entries[]
        | .value + {host: .key, rev: $rev}
      ]
      | sort_by(.host)
    ' <<< "$deployables"
)"

pins="$(cachix_fetch_pins "$cache_name")"

deploy_info_json="$(
  jq -cn \
    --argjson pins "$pins" \
    --argjson proofs "$proofs_json" \
    '
      def pinPath($name):
        (($pins[]? | select(.name == $name) | .lastRevision.storePath) // "");

      $proofs
      | map(
          .deployPin as $deployPin
          | pinPath($deployPin) as $deployed
          | . + {
              deployed: $deployed,
              changed: ($deployed != .storePath)
            }
        )
      | sort_by(.host)
    '
)"

selected_json="$(
  jq -cn \
    --arg force "$force" \
    --argjson requested "$requested_hosts_json" \
    --argjson deployInfo "$deploy_info_json" \
    '
      $deployInfo
      | map(select(.host as $host | $requested | index($host)))
      | if $force == "true" then
          .
        else
          map(select(.changed))
        end
    '
)"

selected_count="$(jq -r 'length' <<< "$selected_json")"
matrix="$(jq -cn --argjson include "$selected_json" '{include: ($include | map({host, system, storePath, rollbackScript}))}')"
deploy_plan="$(jq -cn --argjson include "$selected_json" '{include: $include}')"
selected_hosts="$(jq -r 'if length == 0 then "[none]" else map(.host) | join(", ") end' <<< "$selected_json")"

echo "Cachix deploy plan:"
echo "  event:    ${event_name:-[unknown]}"
echo "  hosts:    ${trimmed_hosts:-[preview]}"
echo "  force:    $force"
echo "  preview:  $preview"
echo "  selected: $selected_hosts"

echo "Host deployment state:"
printf '%-24s %-7s %-48s %s\n' "host" "change" "deployed" "built"
printf '%-24s %-7s %-48s %s\n' "----" "------" "--------" "-----"
while IFS=$'\t' read -r host changed deployed built; do
  printf '%-24s %-7s %-48s %s\n' "$host" "$changed" "${deployed:-[none]}" "$built"
done < <(
  jq -r '
    .[]
    | [
        .host,
        .changed,
        (if ((.deployed // "") == "") then "[none]" else .deployed end),
        .storePath
      ]
    | @tsv
  ' <<< "$deploy_info_json"
)

if [ "$preview" = "true" ]; then
  selected_count=0
  matrix='{"include":[]}'
  deploy_plan='{"include":[]}'
else
  mapfile -t selected_paths < <(
    jq -r '.[] | .storePath, .rollbackScript' <<< "$selected_json"
  )
  cachix_verify_store_paths "$cache_name" "${selected_paths[@]}"
fi

write_output selected_count "$selected_count"
write_output preview "$preview"
write_output selected_hosts "$selected_hosts"

printf '%s\n' "$matrix" > "$output_dir/deploy-matrix.json"
printf '%s\n' "$deploy_plan" > "$output_dir/deploy-plan.json"
