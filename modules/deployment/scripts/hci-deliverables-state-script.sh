#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-}"
deliverables_json="${DELIVERABLES_JSON:-${DEPLOYABLES_JSON:-}}"
deliverables_mode="${HCI_DELIVERABLES_MODE:-${HCI_DEPLOYABLES_MODE:-production}}"
state_name="${HCI_DELIVERABLES_STATE_NAME:-${HCI_DEPLOYABLES_STATE_NAME:-deployables.json}}"
state_history_limit="${HCI_DELIVERABLES_HISTORY_LIMIT:-${HCI_DEPLOYABLES_HISTORY_LIMIT:-10}}"
built_pin_keep_revisions="${CACHIX_BUILT_PIN_KEEP_REVISIONS:-10}"
create_github_deployment="${HCI_CREATE_GITHUB_DEPLOYMENT:-true}"
github_api_url="${GITHUB_API_URL:-https://api.github.com}"
github_repository="${GITHUB_REPOSITORY:-whitestrake/nixos}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
create_github_deployment_script="${CACHIX_CREATE_GITHUB_DEPLOYMENT_SCRIPT:-$script_dir/cachix-create-github-deployment.sh}"
ci_gate_script="${HCI_DELIVERABLES_CI_GATE_SCRIPT:-${HCI_DEPLOYABLES_CI_GATE_SCRIPT:-$script_dir/hci-deployables-ci-gate.sh}}"

if [ -z "$cache_name" ]; then
  echo "ERROR: CACHIX_CACHE_NAME is empty." >&2
  exit 1
fi

if [ -z "${CACHIX_AUTH_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_AUTH_TOKEN is empty." >&2
  exit 1
fi

if [ -z "$deliverables_json" ]; then
  echo "ERROR: DELIVERABLES_JSON is empty." >&2
  exit 1
fi

if [ ! -r "$ci_gate_script" ]; then
  echo "ERROR: CI gate script is not readable: $ci_gate_script" >&2
  exit 1
fi

case "$deliverables_mode" in
  production|canary)
    ;;
  *)
    echo "ERROR: HCI_DELIVERABLES_MODE must be production or canary." >&2
    exit 1
    ;;
esac

case "$create_github_deployment" in
  true|false)
    ;;
  *)
    echo "ERROR: HCI_CREATE_GITHUB_DEPLOYMENT must be true or false." >&2
    exit 1
    ;;
esac

if [ "$create_github_deployment" = "true" ] && [ -z "${GITHUB_DEPLOYMENT_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_DEPLOYMENT_TOKEN is empty." >&2
  exit 1
fi

if ! [[ "$state_history_limit" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HCI_DELIVERABLES_HISTORY_LIMIT must be a positive integer." >&2
  exit 1
fi

if ! [[ "$built_pin_keep_revisions" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: CACHIX_BUILT_PIN_KEEP_REVISIONS must be a positive integer." >&2
  exit 1
fi

# shellcheck disable=SC2016
required_filter='
  type == "object"
    and (.rev | type == "string" and length > 0)
    and (.shortRev | type == "string" and length > 0)
    and (.branch | type == "string" and length > 0)
    and (.ref | type == "string" and length > 0)
    and (.configurations | type == "object" and length > 0)
    and (.deployables | type == "object")
    and all(
      .configurations[];
      (type == "object")
      and (.kind | type == "string" and length > 0)
      and (.jobName | type == "string" and length > 0)
      and (.system | type == "string" and length > 0)
      and (.storePath | type == "string" and startswith("/nix/store/"))
      and (.buildPin | type == "string")
      and (
        if $mode == "production" then
          (.buildPin | startswith("built-host-"))
        else
          (.buildPin | startswith("canary-host-"))
        end
      )
    )
    and all(
      .deployables[];
      (type == "object")
      and (.kind | type == "string" and length > 0)
      and (.jobName | type == "string" and length > 0)
      and (.system | type == "string" and length > 0)
      and (.storePath | type == "string" and startswith("/nix/store/"))
      and (.buildPin | type == "string")
      and (
        if $mode == "production" then
          (.buildPin | startswith("built-host-"))
        else
          (.buildPin | startswith("canary-host-"))
        end
      )
      and (.rollbackScript | type == "string" and startswith("/nix/store/"))
      and (.rollbackPin | type == "string")
      and (
        if $mode == "production" then
          (.rollbackPin | startswith("built-rollback-"))
        else
          (.rollbackPin | startswith("canary-rollback-"))
        end
      )
      and (.deployPin | type == "string" and startswith("deployed-host-"))
    )
'

if ! printf '%s\n' "$deliverables_json" | jq -e --arg mode "$deliverables_mode" "$required_filter" >/dev/null; then
  echo "ERROR: DELIVERABLES_JSON is malformed." >&2
  printf '%s\n' "$deliverables_json" | jq . >&2 || printf '%s\n' "$deliverables_json" >&2
  exit 1
fi

IFS=$'\t' read -r rev short_rev branch < <(
  printf '%s\n' "$deliverables_json" | jq -r '[.rev, .shortRev, .branch] | @tsv'
)
deployables_json="$(
  printf '%s\n' "$deliverables_json" \
    | jq -c '{ref, branch, rev, shortRev, hosts: .deployables}'
)"
work_dir="$(mktemp -d)"
old_state="$work_dir/state-old.json"
new_state="$work_dir/state-new.json"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

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

# shellcheck source=/dev/null
source "$ci_gate_script"

record_deployables_state() {
  local timestamp

  getStateFile "$state_name" "$old_state"

  if [ -e "$old_state" ] && ! jq -e 'type == "object"' "$old_state" >/dev/null; then
    echo "Existing state $state_name is malformed; replacing it." >&2
    rm -f "$old_state"
  fi

  if [ ! -e "$old_state" ]; then
    jq -n '{}' > "$old_state"
  fi

  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq \
    --argjson current "$deployables_json" \
    --arg rev "$rev" \
    --arg timestamp "$timestamp" \
    --argjson limit "$state_history_limit" \
    --argjson ciGate "$ci_gate_json" \
    '
      def currentRecord:
        $current | del(.rev) + {generatedAt: $timestamp, ciGate: $ciGate};

      (
        .[$rev] = currentRecord
        | to_entries
        | sort_by(.value.generatedAt // "")
        | reverse
        | .[:$limit]
        | from_entries
      )
    ' "$old_state" > "$new_state"

  putStateFile "$state_name" "$new_state"

  echo "Recorded HCI deployables state: $state_name"
  jq -r --arg rev "$rev" '.[$rev] | "  \($rev) " + (.hosts | keys | sort | join(", "))' "$new_state"
}

set +e
ci_gate_json="$(run_deployables_ci_gate "$deliverables_json")"
ci_gate_status=$?
set -e

if [ "$ci_gate_status" -ne 0 ]; then
  record_deployables_state
  echo "CI gate blocked deployables state side effects; state was recorded for inspection." >&2
  exit "$ci_gate_status"
fi

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
  local path="$2"
  local payload

  case "$deliverables_mode:$pin_name" in
    production:built-host-*|production:built-rollback-*|canary:canary-host-*|canary:canary-rollback-*)
      ;;
    *)
      echo "ERROR: refusing to update unexpected pin: $pin_name" >&2
      return 1
      ;;
  esac

  payload="$(
    jq -n \
      --arg name "$pin_name" \
      --arg storePath "$path" \
      --argjson keepRevisions "$built_pin_keep_revisions" \
      '{name: $name, storePath: $storePath, artifacts: [], keep: {tag: "Revisions", contents: $keepRevisions}}'
  )"

  with_retry curl -fsS \
    -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "https://app.cachix.org/api/v1/cache/$cache_name/pin" \
    >/dev/null
}

dispatch_github_deployment() {
  local matrix="$1"
  local selected_count="$2"
  local matrix_file

  if [ "$selected_count" = "0" ]; then
    echo "No deployable hosts changed; not creating a GitHub Deployment."
    return 0
  fi

  if [ "$create_github_deployment" = "false" ]; then
    echo "GitHub Deployment creation disabled for $deliverables_mode deliverables."
    return 0
  fi

  matrix_file="$work_dir/deployment-matrix.json"
  printf '%s\n' "$matrix" > "$matrix_file"

  CACHIX_DEPLOY_REV="$rev" \
    CACHIX_DEPLOY_SHORT_REV="$short_rev" \
    CACHIX_DEPLOY_BRANCH="$branch" \
    CACHIX_DEPLOY_SOURCE="hercules-ci" \
    CACHIX_DEPLOY_MATRIX_FILE="$matrix_file" \
    GITHUB_API_URL="$github_api_url" \
    GITHUB_REPOSITORY="$github_repository" \
    GITHUB_DEPLOYMENT_TOKEN="$GITHUB_DEPLOYMENT_TOKEN" \
    bash "$create_github_deployment_script"
}

pins="$(fetch_pins)"

while IFS=$'\t' read -r host build_pin store_path; do
  previous_built="$(pin_path "$build_pin")"
  if [ "$previous_built" = "$store_path" ]; then
    echo "Built state already pinned for $host:"
    echo "  $build_pin -> $store_path"
  else
    echo "Built state differs for $host:"
    echo "  previous: ${previous_built:-[none]}"
    echo "  current:  $store_path"
    echo "Pinning built state: $build_pin -> $store_path"
    pin_state "$build_pin" "$store_path"
  fi
done < <(
  printf '%s\n' "$deliverables_json" \
    | jq -r '
        .configurations
        | to_entries[]
        | [
            .key,
            .value.buildPin,
            .value.storePath
          ]
        | @tsv
      '
)

while IFS=$'\t' read -r host rollback_pin rollback_script; do
  previous_rollback="$(pin_path "$rollback_pin")"
  if [ "$previous_rollback" = "$rollback_script" ]; then
    echo "Rollback script already pinned for $host:"
    echo "  $rollback_pin -> $rollback_script"
  else
    echo "Rollback script differs for $host:"
    echo "  previous: ${previous_rollback:-[none]}"
    echo "  current:  $rollback_script"
    echo "Pinning rollback script: $rollback_pin -> $rollback_script"
    pin_state "$rollback_pin" "$rollback_script"
  fi
done < <(
  printf '%s\n' "$deployables_json" \
    | jq -r '
        .hosts
        | to_entries[]
        | [
            .key,
            .value.rollbackPin,
            .value.rollbackScript
          ]
        | @tsv
      '
)

record_deployables_state

deployment_matrix="$(
  printf '%s\n' "$deployables_json" \
    | jq -c \
      --argjson pins "$pins" \
      '
        def pinPath($name):
          (($pins[]? | select(.name == $name) | .lastRevision.storePath) // "");

        {
          include: (
            [
              .hosts
              | to_entries[]
              | .value + {host: .key}
              | select(pinPath(.deployPin) != .storePath)
              | {
                  host,
                  system,
                  storePath,
                  rollbackScript
                }
            ]
            | sort_by(.host)
          )
        }
      '
)"

selected_count="$(jq -r '.include | length' <<< "$deployment_matrix")"
dispatch_github_deployment "$deployment_matrix" "$selected_count"
