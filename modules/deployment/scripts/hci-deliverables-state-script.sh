#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-}"
mode="${HCI_DEPLOYMENT_MODE:-production}"
rev="${HCI_DEPLOYMENT_REV:-}"
branch="${HCI_DEPLOYMENT_BRANCH:-master}"
hci_project="${HCI_PROJECT:-github/whitestrake/nixos}"
required_job_names="${HCI_REQUIRED_JOB_NAMES:-[]}"
built_jobs="${HCI_BUILT_JOBS:-[]}"
deployable_jobs="${HCI_DEPLOYABLE_JOBS:-[]}"
built_pin_keep_revisions="${CACHIX_BUILT_PIN_KEEP_REVISIONS:-10}"
create_github_deployment="${HCI_CREATE_GITHUB_DEPLOYMENT:-true}"
github_api_url="${GITHUB_API_URL:-https://api.github.com}"
github_repository="${GITHUB_REPOSITORY:-whitestrake/nixos}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
create_github_deployment_script="${CACHIX_CREATE_GITHUB_DEPLOYMENT_SCRIPT:-$script_dir/cachix-create-github-deployment.sh}"

# shellcheck source=modules/deployment/scripts/cachix-pin-functions.sh
source "${CACHIX_PIN_FUNCTIONS_SCRIPT:-$script_dir/cachix-pin-functions.sh}"

if [ -z "$cache_name" ]; then
  echo "ERROR: CACHIX_CACHE_NAME is empty." >&2
  exit 1
fi

if [ -z "$rev" ]; then
  echo "ERROR: HCI_DEPLOYMENT_REV is empty." >&2
  exit 1
fi

if [ -z "${CACHIX_AUTH_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_AUTH_TOKEN is empty." >&2
  exit 1
fi

case "$mode" in
  production|canary)
    ;;
  *)
    echo "ERROR: HCI_DEPLOYMENT_MODE must be production or canary." >&2
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

if ! jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' <<< "$required_job_names" >/dev/null; then
  echo "ERROR: HCI_REQUIRED_JOB_NAMES must be a JSON array of strings." >&2
  exit 1
fi

if ! jq -e '
  type == "array"
  and all(.[]; (
    (.host | type == "string" and length > 0)
    and (.jobName | type == "string" and length > 0)
    and (.toplevelAttrPath | type == "array" and length > 0)
    and (.buildPin | type == "string" and startswith("built-host-"))
  ))
' <<< "$built_jobs" >/dev/null; then
  echo "ERROR: HCI_BUILT_JOBS is malformed." >&2
  exit 1
fi

if ! jq -e '
  type == "array"
  and all(.[]; (
    (.host | type == "string" and length > 0)
    and (.system | type == "string" and length > 0)
    and (.jobName | type == "string" and length > 0)
    and (.toplevelAttrPath | type == "array" and length > 0)
    and (.rollbackAttrPath | type == "array" and length > 0)
    and (.deployPin | type == "string" and startswith("deployed-host-"))
  ))
' <<< "$deployable_jobs" >/dev/null; then
  echo "ERROR: HCI_DEPLOYABLE_JOBS is malformed." >&2
  exit 1
fi

if ! [[ "$built_pin_keep_revisions" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: CACHIX_BUILT_PIN_KEEP_REVISIONS must be a positive integer." >&2
  exit 1
fi

IFS=/ read -r hci_site hci_account hci_repo extra <<< "$hci_project"
if [ -z "${hci_site:-}" ] || [ -z "${hci_account:-}" ] || [ -z "${hci_repo:-}" ] || [ -n "${extra:-}" ]; then
  echo "ERROR: HCI_PROJECT must have the form site/account/project, got: $hci_project" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

hci_api_get() {
  local path="$1"
  local token="${HERCULES_CI_API_TOKEN:-${HCI_API_TOKEN:-${HERCULES_CI_TOKEN:-}}}"
  local api_base_url="${HERCULES_CI_API_BASE_URL:-https://hercules-ci.com}"
  local api_url="${HCI_API_URL:-${api_base_url%/}/api/v1}"

  if [ -n "$token" ]; then
    curl -fsS -H "Authorization: Bearer $token" "${api_url%/}$path"
    return
  fi

  curl -fsS "${api_url%/}$path"
}

urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

fetch_project() {
  hci_api_get "/site/$hci_site/account/$hci_account/project/$hci_repo"
}

fetch_jobs_page() {
  local offset="${1:-}"
  local path="/site/$hci_site/account/$hci_account/project/$hci_repo/jobs?rev=$rev&handler=OnPush&limit=100"

  if [ -n "$offset" ]; then
    path="$path&offsetIndex=$offset"
  fi

  hci_api_get "$path"
}

fetch_jobs() {
  local offset="" page next
  : > "$work_dir/jobs.ndjson"

  while true; do
    page="$(fetch_jobs_page "$offset")"
    jq -c '.items[]?' <<< "$page" >> "$work_dir/jobs.ndjson"

    if [ "$(jq -r '.more' <<< "$page")" != "true" ]; then
      break
    fi

    next="$(jq -r '[.items[]?.index] | max // empty' <<< "$page")"
    if [ -z "$next" ]; then
      echo "ERROR: HCI jobs response has more=true but no item index to continue paging." >&2
      exit 1
    fi
    offset="$next"
  done

  jq -s -c . "$work_dir/jobs.ndjson"
}

assert_required_jobs_green() {
  local jobs="$1"

  jq -e -n \
    --argjson jobs "$jobs" \
    --argjson required "$required_job_names" \
    --arg rev "$rev" \
    '
      def success: (. // "" | tostring | ascii_downcase) == "success";
      def done: (. // "" | tostring | ascii_downcase) == "done";
      def latest($name): [$jobs[]? | select(.source.revision == $rev and .jobName == $name)] | sort_by(.index // 0) | last;
      [
        $required[] as $name
        | latest($name) as $job
        | {
            jobName: $name,
            found: ($job != null),
            green: (
              ($job != null)
              and ($job.jobPhase | done)
              and ($job.jobStatus | success)
              and ([$job.evaluationStatus, $job.derivationStatus, $job.effectsStatus] | map(. // "Success") | all(success))
            )
          }
      ] as $checked
      | if all($checked[]; .green) then
          true
        else
          error("HCI jobs are not all green: " + ($checked | map(select(.green | not).jobName) | join(", ")))
        end
    ' >/dev/null
}

job_id_for_name() {
  local jobs="$1"
  local job_name="$2"

  jq -er \
    --arg rev "$rev" \
    --arg jobName "$job_name" \
    '
      [.[] | select(.source.revision == $rev and .jobName == $jobName)]
      | sort_by(.index // 0)
      | last.id
    ' <<< "$jobs"
}

fetch_evaluation() {
  local job_id="$1"
  hci_api_get "/jobs/$job_id/evaluation"
}

derivation_for_attr() {
  local evaluation="$1"
  local attr_path="$2"

  jq -er \
    --argjson path "$attr_path" \
    '
      .attributes[]
      | select(.path == $path)
      | .value.Ok.derivationPath
    ' <<< "$evaluation"
}

output_for_derivation() {
  local account_id="$1"
  local job_id="$2"
  local drv="$3"
  local encoded_drv

  encoded_drv="$(urlencode "$drv")"
  hci_api_get "/accounts/$account_id/derivations/$encoded_drv?via-job=$job_id" \
    | jq -er '.outputs[] | select(.outputName == "out") | .outputPath'
}

assemble_deploy_info() {
  local account_id="$1"
  local jobs="$2"
  local record job_id evaluation toplevel_drv rollback_drv store_path rollback_script
  local out="$work_dir/deploy-info.ndjson"

  : > "$out"
  while IFS= read -r record; do
    job_id="$(job_id_for_name "$jobs" "$(jq -r '.jobName' <<< "$record")")"
    evaluation="$(fetch_evaluation "$job_id")"
    toplevel_drv="$(derivation_for_attr "$evaluation" "$(jq -c '.toplevelAttrPath' <<< "$record")")"
    rollback_drv="$(derivation_for_attr "$evaluation" "$(jq -c '.rollbackAttrPath' <<< "$record")")"
    store_path="$(output_for_derivation "$account_id" "$job_id" "$toplevel_drv")"
    rollback_script="$(output_for_derivation "$account_id" "$job_id" "$rollback_drv")"

    jq -c \
      --argjson record "$record" \
      --arg storePath "$store_path" \
      --arg rollbackScript "$rollback_script" \
      '$record + {storePath: $storePath, rollbackScript: $rollbackScript}' \
      <<< '{}' >> "$out"
  done < <(jq -c '.[]' <<< "$deployable_jobs")

  jq -s -c 'sort_by(.host)' "$out"
}

assemble_built_info() {
  local account_id="$1"
  local jobs="$2"
  local record job_id evaluation toplevel_drv store_path
  local out="$work_dir/built-info.ndjson"

  : > "$out"
  while IFS= read -r record; do
    job_id="$(job_id_for_name "$jobs" "$(jq -r '.jobName' <<< "$record")")"
    evaluation="$(fetch_evaluation "$job_id")"
    toplevel_drv="$(derivation_for_attr "$evaluation" "$(jq -c '.toplevelAttrPath' <<< "$record")")"
    store_path="$(output_for_derivation "$account_id" "$job_id" "$toplevel_drv")"

    jq -c \
      --argjson record "$record" \
      --arg storePath "$store_path" \
      '$record + {storePath: $storePath}' \
      <<< '{}' >> "$out"
  done < <(jq -c '.[]' <<< "$built_jobs")

  jq -s -c 'sort_by(.host)' "$out"
}

dispatch_github_deployment() {
  local matrix="$1"
  local selected_count="$2"
  local matrix_file

  if [ "$selected_count" = "0" ]; then
    echo "No deployable hosts changed; not dispatching Cachix deploy workflow."
    return 0
  fi

  if [ "$create_github_deployment" = "false" ]; then
    echo "Cachix deploy workflow dispatch disabled for $mode deployables."
    return 0
  fi

  matrix_file="$work_dir/deployment-matrix.json"
  printf '%s\n' "$matrix" > "$matrix_file"

  CACHIX_DEPLOY_REV="$rev" \
    CACHIX_DEPLOY_BRANCH="$branch" \
    CACHIX_DEPLOY_SOURCE="hercules-ci" \
    CACHIX_DEPLOY_FORCE=false \
    CACHIX_DEPLOY_MATRIX_FILE="$matrix_file" \
    GITHUB_API_URL="$github_api_url" \
    GITHUB_REPOSITORY="$github_repository" \
    GITHUB_DEPLOYMENT_TOKEN="$GITHUB_DEPLOYMENT_TOKEN" \
    bash "$create_github_deployment_script"
}

project="$(fetch_project)"
account_id="$(jq -er '.owner.id' <<< "$project")"
jobs="$(fetch_jobs)"
assert_required_jobs_green "$jobs"
built_info="$(assemble_built_info "$account_id" "$jobs")"
deploy_info="$(assemble_deploy_info "$account_id" "$jobs")"
pins="$(cachix_fetch_pins "$cache_name")"

while IFS=$'\t' read -r host build_pin store_path; do
  previous_built="$(cachix_pin_path "$pins" "$build_pin")"
  if [ "$previous_built" = "$store_path" ]; then
    echo "Built state already pinned for $host:"
    echo "  $build_pin -> $store_path"
  else
    echo "Built state differs for $host:"
    echo "  previous: ${previous_built:-[none]}"
    echo "  current:  $store_path"
    echo "Pinning built state: $build_pin -> $store_path"
    cachix_pin_store_path "$cache_name" "$build_pin" "$store_path" "$built_pin_keep_revisions"
  fi
done < <(
  jq -r '
    .[]
    | [
        .host,
        .buildPin,
        .storePath
      ]
    | @tsv
  ' <<< "$built_info"
)

deployment_matrix="$(
  jq -c -n \
    --argjson deployInfo "$deploy_info" \
    --argjson pins "$pins" \
    '
      def pinPath($name):
        (($pins[]? | select(.name == $name) | .lastRevision.storePath) // "");

      {
        include: (
          $deployInfo
          | map(select(pinPath(.deployPin) != .storePath))
          | map({host, system, storePath, rollbackScript})
          | sort_by(.host)
        )
      }
    '
)"

echo "HCI deploy matrix for $rev ($mode):"
jq . <<< "$deployment_matrix"

selected_count="$(jq -r '.include | length' <<< "$deployment_matrix")"
dispatch_github_deployment "$deployment_matrix" "$selected_count"
