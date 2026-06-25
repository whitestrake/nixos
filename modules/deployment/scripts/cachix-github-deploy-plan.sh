#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-whitestrake}"
hci_project="${HCI_PROJECT:-github/whitestrake/nixos}"
hci_api_base="${HCI_API_BASE_URL:-https://hercules-ci.com}"
rev="${CACHIX_DEPLOY_REV:-${GITHUB_SHA:-}}"
hosts_raw="${CACHIX_DEPLOY_HOSTS:-}"
force="${CACHIX_DEPLOY_FORCE:-false}"
event_name="${GITHUB_EVENT_NAME:-}"
output_dir="${CACHIX_DEPLOY_OUTPUT_DIR:-$PWD}"
wait_timeout="${HCI_WAIT_TIMEOUT_SECONDS:-3600}"
poll_seconds="${HCI_POLL_SECONDS:-30}"

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

if ! [[ "$wait_timeout" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HCI_WAIT_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 1
fi

if ! [[ "$poll_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HCI_POLL_SECONDS must be a positive integer." >&2
  exit 1
fi

if [ -z "${HERCULES_CI_CREDENTIALS_JSON:-}" ]; then
  echo "ERROR: HERCULES_CI_CREDENTIALS_JSON is empty." >&2
  exit 1
fi

if [ -z "${CACHIX_AUTH_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_AUTH_TOKEN is empty." >&2
  exit 1
fi

IFS=/ read -r hci_site hci_account hci_repo extra <<< "$hci_project"
if [ -z "${hci_site:-}" ] || [ -z "${hci_account:-}" ] || [ -z "${hci_repo:-}" ] || [ -n "${extra:-}" ]; then
  echo "ERROR: HCI_PROJECT must have the form site/account/project, got: $hci_project" >&2
  exit 1
fi

hci_api_base="${hci_api_base%/}"
jobs_url="$hci_api_base/api/v1/site/$hci_site/account/$hci_account/project/$hci_repo/jobs?limit=100"

setup_hci_credentials() {
  local credentials_dir credentials_file

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

  if ! hci_personal_token="$(
    jq -er '.domains."hercules-ci.com".personalToken | select(type == "string" and length > 0)' \
      "$credentials_file"
  )"; then
    echo "ERROR: HERCULES_CI_CREDENTIALS_JSON must be a Hercules CI credentials.json document." >&2
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

hci_api_get() {
  local url="$1"
  curl -fsS \
    -H "Authorization: Bearer $hci_personal_token" \
    "$url"
}

fetch_pins() {
  with_retry curl -fsS \
    -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
    "https://app.cachix.org/api/v1/cache/$cache_name/pin" \
    | jq -e 'if type == "array" then . else error("Cachix pin API did not return an array") end'
}

wait_for_hci_success() {
  local deadline now jobs rev_jobs count pending failed has_deployables

  deadline="$(($(date +%s) + wait_timeout))"

  while true; do
    jobs="$(hci_api_get "$jobs_url")"
    rev_jobs="$(
      jq -c \
        --arg rev "$rev" \
        '[.items[]? | select(.source.revision == $rev and .jobType == "OnPush")]' \
        <<< "$jobs"
    )"
    count="$(jq -r 'length' <<< "$rev_jobs")"
    has_deployables="$(jq -r 'any(.[]; .jobName == "deployables")' <<< "$rev_jobs")"
    pending="$(
      jq -c '
        [
          .[]
          | select(
              .jobPhase != "Done"
              or .jobStatus != "Success"
              or .derivationStatus != "Success"
              or .effectsStatus != "Success"
            )
        ]
      ' <<< "$rev_jobs"
    )"
    failed="$(
      jq -c '
        [
          .[]
          | select(
              .jobPhase == "Done"
              and (
                .jobStatus != "Success"
                or .derivationStatus != "Success"
                or .effectsStatus != "Success"
              )
            )
        ]
      ' <<< "$rev_jobs"
    )"

    if ! jq -e 'length == 0' <<< "$failed" >/dev/null; then
      echo "ERROR: HCI reported failed jobs for $rev:" >&2
      jq -r '.[] | "  job \(.index) \(.jobName): \(.jobStatus) derivations=\(.derivationStatus) effects=\(.effectsStatus)"' <<< "$failed" >&2
      exit 1
    fi

    if [ "$count" -gt 0 ] && [ "$has_deployables" = "true" ] && jq -e 'length == 0' <<< "$pending" >/dev/null; then
      echo "HCI jobs are green for $rev."
      jq -r '.[] | "  job \(.index) \(.jobName): \(.jobStatus) derivations=\(.derivationStatus) effects=\(.effectsStatus)"' <<< "$rev_jobs"
      return 0
    fi

    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      echo "ERROR: timed out waiting for HCI jobs for $rev." >&2
      echo "Observed $count onPush job(s); deployables job present: $has_deployables" >&2
      jq -r '.[] | "  job \(.index) \(.jobName): phase=\(.jobPhase) status=\(.jobStatus) derivations=\(.derivationStatus) effects=\(.effectsStatus)"' <<< "$rev_jobs" >&2
      exit 1
    fi

    echo "Waiting for HCI jobs for $rev: $count seen, deployables=$has_deployables, pending=$(jq -r 'length' <<< "$pending")"
    sleep "$poll_seconds"
  done
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
  write_output matrix '{"include":[]}'
  write_output selected_count "0"
  write_output preview "$preview_value"
  write_output selected_hosts "[none]"
  printf '%s\n' '{"include":[]}' > "$output_dir/deploy-matrix.json"
}

skip_if_stale_automatic_run() {
  local master_rev

  if [ "$event_name" != "check_suite" ]; then
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
    echo "  check suite revision: $rev"
    echo "  current master:       $master_rev"
    emit_empty_plan false
    exit 0
  fi
}

setup_hci_credentials

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
wait_for_hci_success

if ! deployables_state="$(get_state deployables.json)"; then
  echo "ERROR: failed to read HCI state file deployables.json." >&2
  exit 1
fi

deployables_entry="$(
  jq -c \
    --arg rev "$rev" \
    '
      .[$rev]
      | select(type == "object")
      | select(.deployables | type == "array")
    ' \
    <<< "$deployables_state"
)"

if [ -z "$deployables_entry" ]; then
  echo "ERROR: deployables.json has no deployables entry for $rev." >&2
  echo "HCI status gating should make this impossible; investigate HCI deployables state." >&2
  exit 1
fi

deployables_json="$(jq -c '.deployables | sort' <<< "$deployables_entry")"
if jq -e 'length == 0' <<< "$deployables_json" >/dev/null; then
  echo "ERROR: deployables.json has an empty deployables list for $rev." >&2
  echo "At least one deployable Cachix agent host is expected on master." >&2
  exit 1
fi
echo "Deployables for $rev: $(jq -r 'join(", ")' <<< "$deployables_json")"

proofs_file="$output_dir/build-proofs.jsonl"
: > "$proofs_file"

while IFS= read -r host; do
  if ! host_state="$(get_state "built-host-$host.json")"; then
    echo "ERROR: deployables.json says $host is deployable for $rev, but built-host-$host.json could not be read." >&2
    echo "HCI status gating should make this impossible; investigate HCI state/effect ordering." >&2
    exit 1
  fi

  proof="$(
    jq -c \
      --arg host "$host" \
      --arg rev "$rev" \
      '
        .[$host][$rev]
        | select(type == "object")
        | select(.deployable == true)
        | select(.storePath | type == "string" and startswith("/nix/store/"))
        | select(.rollbackScript | type == "string" and startswith("/nix/store/"))
        | select(.system | type == "string" and length > 0)
      ' \
      <<< "$host_state"
  )"

  if [ -z "$proof" ]; then
    echo "ERROR: deployables.json says $host is deployable for $rev, but built-host-$host.json has no build proof for that revision." >&2
    echo "HCI status gating should make this impossible; investigate HCI state/effect ordering." >&2
    exit 1
  fi

  jq -cn \
    --arg host "$host" \
    --arg rev "$rev" \
    --argjson proof "$proof" \
    '$proof + {host: $host, rev: $rev}' \
    >> "$proofs_file"
done < <(jq -r '.[]' <<< "$deployables_json")

proofs_json="$(jq -sc '.' "$proofs_file")"

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

pins="$(fetch_pins)"

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
          pinPath("deployed-host-" + .host) as $deployed
          | . + {
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
matrix="$(jq -cn --argjson include "$selected_json" '{include: $include}')"
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
fi

write_output matrix "$matrix"
write_output selected_count "$selected_count"
write_output preview "$preview"
write_output selected_hosts "$selected_hosts"

printf '%s\n' "$matrix" > "$output_dir/deploy-matrix.json"
