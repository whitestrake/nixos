#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-whitestrake}"
hci_project="${HCI_PROJECT:-github/whitestrake/nixos}"
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

IFS=/ read -r hci_site hci_account hci_repo extra <<< "$hci_project"
if [ -z "${hci_site:-}" ] || [ -z "${hci_account:-}" ] || [ -z "${hci_repo:-}" ] || [ -n "${extra:-}" ]; then
  echo "ERROR: HCI_PROJECT must have the form site/account/project, got: $hci_project" >&2
  exit 1
fi

setup_hci_credentials() {
  local credentials_dir credentials_file

  if [ -z "${HERCULES_CI_CREDENTIALS_JSON:-}" ]; then
    echo "ERROR: HERCULES_CI_CREDENTIALS_JSON is empty." >&2
    exit 1
  fi

  if [ -z "${HOME:-}" ]; then
    echo "ERROR: HOME must be set so hci can read credentials." >&2
    exit 1
  fi

  credentials_dir="$HOME/.config/hercules-ci"
  credentials_file="$credentials_dir/credentials.json"

  mkdir -p "$credentials_dir"
  chmod 0700 "$credentials_dir"
  printf '%s\n' "$HERCULES_CI_CREDENTIALS_JSON" > "$credentials_file"
  chmod 0600 "$credentials_file"

  if ! jq -e '.domains."hercules-ci.com".personalToken | select(type == "string" and length > 0)' \
    "$credentials_file" >/dev/null; then
    echo "ERROR: HERCULES_CI_CREDENTIALS_JSON must be a Hercules CI credentials.json document." >&2
    exit 1
  fi
}

get_state() {
  local state_name="$1"
  hci state get --project "$hci_project" --name "$state_name" --file -
}

write_output() {
  local name="$1"
  local value="$2"

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
  fi
}

emit_empty_plan() {
  local preview_value="$1"

  mkdir -p "$output_dir"
  write_output selected_count "0"
  write_output preview "$preview_value"
  write_output selected_hosts "[none]"
  printf '%s\n' '{"include":[]}' > "$output_dir/deploy-matrix.json"
  printf '%s\n' '{"include":[]}' > "$output_dir/deploy-plan.json"
}

skip_if_stale_automatic_run() {
  local master_rev

  if [ "$event_name" = "workflow_dispatch" ]; then
    return 0
  fi

  if ! master_rev="$(git ls-remote origin refs/heads/master | awk '{print $1}')"; then
    echo "ERROR: failed to query origin master for stale deploy protection." >&2
    exit 1
  fi

  if [ -z "$master_rev" ]; then
    echo "ERROR: origin refs/heads/master did not resolve." >&2
    exit 1
  fi

  if [ "$rev" != "$master_rev" ]; then
    echo "Skipping stale automatic deploy:"
    echo "  workflow revision: $rev"
    echo "  current master:    $master_rev"
    emit_empty_plan false
    exit 0
  fi
}

trimmed_hosts="$(
  jq -rn --arg hosts "$hosts_raw" '$hosts | gsub("^\\s+|\\s+$"; "")'
)"

preview=false
if [ "$event_name" = "workflow_dispatch" ] && [ -z "$trimmed_hosts" ]; then
  preview=true
fi

if [ "$event_name" != "workflow_dispatch" ] && [ -z "$trimmed_hosts" ]; then
  trimmed_hosts="all"
fi

mkdir -p "$output_dir"

skip_if_stale_automatic_run
setup_hci_credentials
skip_if_stale_automatic_run

if ! deployables_state="$(get_state deployables.json)"; then
  echo "ERROR: failed to read HCI state file deployables.json." >&2
  exit 1
fi

if ! canary_deployables_state="$(get_state canary-deployables.json 2>/dev/null)"; then
  canary_deployables_state='{}'
fi

deployables_entry="$(
  jq -c -n \
    --arg rev "$rev" \
    --argjson production "$deployables_state" \
    --argjson canary "$canary_deployables_state" \
    '
      if $production | has($rev) then
        $production[$rev]
      elif $canary | has($rev) then
        $canary[$rev]
      else
        null
      end
    '
)"

if [ -z "$deployables_entry" ] || [ "$deployables_entry" = "null" ]; then
  echo "ERROR: no complete deployables entry for $rev." >&2
  echo "Checked HCI state files: deployables.json and canary-deployables.json." >&2
  exit 1
fi

if ! jq -e 'type == "object"' <<< "$deployables_entry" >/dev/null; then
  echo "ERROR: HCI deployables state entry for $rev is malformed." >&2
  jq . <<< "$deployables_entry" >&2 || true
  exit 1
fi

if ! jq -e '(.ciGate | type) == "object" and .ciGate.state == "passed"' <<< "$deployables_entry" >/dev/null; then
  echo "ERROR: deployables entry for $rev is not deployable because ciGate.state is not passed." >&2
  jq -r '
    if has("ciGate") | not then
      "  ciGate is missing"
    elif (.ciGate | type) == "object" then
      .ciGate | "  ciGate.state: \(.state // "unknown")"
    else
      "  ciGate is malformed: expected object, got \(.ciGate | type)"
    end
  ' <<< "$deployables_entry" >&2
  exit 1
fi

if ! jq -e '(.hosts | type) == "object" and (.hosts | length) > 0' <<< "$deployables_entry" >/dev/null; then
  echo "ERROR: no complete deployables entry for $rev." >&2
  echo "Checked HCI state files: deployables.json and canary-deployables.json." >&2
  exit 1
fi

invalid_hosts_json="$(
  jq -c '
    [
      .hosts
      | to_entries[]
      | select(
          (.value | type) != "object"
          or (.value.system | type != "string" or (.value.system | length) == 0)
          or (.value.storePath | type != "string" or (.value.storePath | startswith("/nix/store/") | not))
          or (.value.rollbackScript | type != "string" or (.value.rollbackScript | startswith("/nix/store/") | not))
        )
      | .key
    ]
  ' <<< "$deployables_entry"
)"

if ! jq -e 'length == 0' <<< "$invalid_hosts_json" >/dev/null; then
  echo "ERROR: HCI deployables state has malformed host records for $rev:" >&2
  jq -r '.[] | "  " + .' <<< "$invalid_hosts_json" >&2
  exit 1
fi

deployables_json="$(jq -c '.hosts | keys | sort' <<< "$deployables_entry")"
if jq -e 'length == 0' <<< "$deployables_json" >/dev/null; then
  echo "ERROR: HCI deployables state has an empty deployables list for $rev." >&2
  echo "At least one deployable Cachix agent host is expected." >&2
  exit 1
fi
echo "Deployables for $rev: $(jq -r 'join(", ")' <<< "$deployables_json")"

proofs_json="$(
  jq -c \
    --arg rev "$rev" \
    '
      [
        .hosts
        | to_entries[]
        | .value + {host: .key, rev: $rev}
      ]
      | sort_by(.host)
    ' <<< "$deployables_entry"
)"

if [ "$trimmed_hosts" = "all" ] || [ -z "$trimmed_hosts" ]; then
  requested_hosts_json="$deployables_json"
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
      --argjson available "$deployables_json" \
      '$requested | map(. as $host | select(($available | index($host)) | not))'
  )"

  if ! jq -e 'length == 0' <<< "$unknown_hosts_json" >/dev/null; then
    while IFS= read -r host; do
      echo "ERROR: unknown or non-deployable host: $host" >&2
    done < <(jq -r '.[]' <<< "$unknown_hosts_json")
    exit 1
  fi
fi

pins="$(cachix_fetch_pins "$cache_name")"

deploy_info_json="$(
  jq -cn \
    --argjson pins "$pins" \
    --argjson proofs "$proofs_json" \
    '
      def pinPath($name):
        (($pins[]? | select(.name == $name) | .lastRevision.storePath) // "");

      $proofs
      | sort_by(.host)
      | map(
          (.deployPin // ("deployed-host-" + .host)) as $deployPin
          | pinPath($deployPin) as $deployed
          | . + {
              deployPin: $deployPin,
              deployed: $deployed,
              changed: ($deployed != .storePath)
            }
        )
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
matrix="$(jq -cn --argjson include "$selected_json" '{include: ($include | map({host: .host}))}')"
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
fi

write_output selected_count "$selected_count"
write_output preview "$preview"
write_output selected_hosts "$selected_hosts"

printf '%s\n' "$matrix" > "$output_dir/deploy-matrix.json"
printf '%s\n' "$deploy_plan" > "$output_dir/deploy-plan.json"
