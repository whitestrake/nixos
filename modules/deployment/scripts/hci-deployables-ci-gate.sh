#!/usr/bin/env bash

ci_gate_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

ci_gate_event() {
  local event="$1"
  local details_json="${2:-}"
  local payload

  if [ -z "$details_json" ]; then
    details_json="{}"
  fi

  payload="$(
    jq -c -n \
      --arg event "$event" \
      --arg timestamp "$(ci_gate_timestamp)" \
      --argjson details "$details_json" \
      '$details + {event: $event, timestamp: $timestamp}' \
      2>/dev/null
  )" || payload=""

  if [ -z "$payload" ]; then
    payload="$(
      jq -c -n \
        --arg event "$event" \
        --arg timestamp "$(ci_gate_timestamp)" \
        --arg detailsRaw "$details_json" \
        '{event: $event, timestamp: $timestamp, detailsRaw: $detailsRaw}'
    )"
  fi

  printf 'CI_GATE_EVENT %s\n' "$payload" >&2
}

ci_gate_result() {
  printf 'CI_GATE_RESULT %s\n' "$1" >&2
}

ci_gate_positive_integer() {
  local name="$1"
  local value="$2"

  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: %s must be a positive integer, got: %s\n' "$name" "$value" >&2
    return 1
  fi
}

ci_gate_validate_config() {
  local hci_project="${HCI_PROJECT:-github/whitestrake/nixos}"

  ci_gate_positive_integer HCI_CI_GATE_TIMEOUT_SECONDS "${HCI_CI_GATE_TIMEOUT_SECONDS:-3600}" || return 1
  ci_gate_positive_integer HCI_CI_GATE_HCI_TIMEOUT_SECONDS "${HCI_CI_GATE_HCI_TIMEOUT_SECONDS:-${HCI_CI_GATE_TIMEOUT_SECONDS:-3600}}" || return 1
  ci_gate_positive_integer HCI_CI_GATE_POLL_INTERVAL_SECONDS "${HCI_CI_GATE_POLL_INTERVAL_SECONDS:-30}" || return 1
  ci_gate_positive_integer HCI_CI_GATE_CONNECT_TIMEOUT_SECONDS "${HCI_CI_GATE_CONNECT_TIMEOUT_SECONDS:-10}" || return 1
  ci_gate_positive_integer HCI_CI_GATE_REQUEST_TIMEOUT_SECONDS "${HCI_CI_GATE_REQUEST_TIMEOUT_SECONDS:-60}" || return 1
  ci_gate_positive_integer HCI_CI_GATE_GITHUB_STATUS_PAGES "${HCI_CI_GATE_GITHUB_STATUS_PAGES:-5}" || return 1
  ci_gate_positive_integer HCI_CI_GATE_HCI_LATEST_JOBS "${HCI_CI_GATE_HCI_LATEST_JOBS:-100}" || return 1

  if [[ ! "$hci_project" =~ ^[^/]+/[^/]+/[^/]+$ ]]; then
    printf 'ERROR: HCI_PROJECT must have the form site/account/project, got: %s\n' "$hci_project" >&2
    return 1
  fi
}

ci_gate_required_jobs() {
  jq -c '[.hosts[]?.jobName | select(type == "string" and length > 0)] | unique' <<< "$1"
}

ci_gate_required_contexts() {
  local jobs="$1"
  local prefix="${HCI_CI_GATE_GITHUB_CONTEXT_PREFIX:-ci/hercules/onPush/}"
  local deployment_context="${prefix}${HCI_DEPLOYMENT_JOB_NAME:-99-deployment}"
  local gate_context="${HCI_CI_GATE_STATUS_CONTEXT:-ci/hercules/deployables-ci-gate}"

  jq -c \
    --arg prefix "$prefix" \
    --arg deploymentContext "$deployment_context" \
    --arg gateContext "$gate_context" \
    'map($prefix + .) | map(select(. != $deploymentContext and . != $gateContext))' \
    <<< "$jobs"
}

ci_gate_fetch_github() {
  local revision="$1"
  local api_url="${github_api_url:-${GITHUB_API_URL:-https://api.github.com}}"
  local repository="${github_repository:-${GITHUB_REPOSITORY:-whitestrake/nixos}}"
  local token="${CI_GATE_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
  local connect_timeout="${HCI_CI_GATE_CONNECT_TIMEOUT_SECONDS:-10}"
  local max_time="${HCI_CI_GATE_REQUEST_TIMEOUT_SECONDS:-60}"
  local max_pages="${HCI_CI_GATE_GITHUB_STATUS_PAGES:-5}"
  local page page_body count all_statuses
  local curl_args=(
    curl -fsS
    --connect-timeout "$connect_timeout"
    --max-time "$max_time"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )

  if [ -n "${CI_GATE_GITHUB_STATUSES_FILE:-}" ]; then
    [ -r "$CI_GATE_GITHUB_STATUSES_FILE" ] || {
      echo "CI_GATE_GITHUB_STATUSES_FILE is not readable: $CI_GATE_GITHUB_STATUSES_FILE" >&2
      return 1
    }
    cat "$CI_GATE_GITHUB_STATUSES_FILE"
    return
  fi

  [ -n "$revision" ] || {
    echo "missing commit revision for GitHub status lookup" >&2
    return 1
  }
  [ -n "$token" ] || {
    echo "GITHUB_TOKEN is required for GitHub status lookup" >&2
    return 1
  }

  curl_args+=(-H "Authorization: Bearer $token")
  all_statuses='[]'
  for ((page = 1; page <= max_pages; page++)); do
    page_body="$("${curl_args[@]}" "${api_url%/}/repos/$repository/commits/$revision/statuses?per_page=100&page=$page")" || return
    all_statuses="$(jq -c -n --argjson current "$all_statuses" --argjson page "$page_body" '$current + $page')" || return
    count="$(jq -er 'if type == "array" then length else error("GitHub statuses response was not an array") end' <<< "$page_body")" || return

    if [ "$count" -lt 100 ]; then
      break
    fi
  done

  printf '%s\n' "$all_statuses"
}

ci_gate_eval_github() {
  jq -c -n \
    --argjson statuses "$1" \
    --argjson required "$2" \
    '
      def latest($context): [$statuses[]? | select(.context == $context)] | sort_by(.updated_at // .created_at // "") | last;
      [$required[] as $context | latest($context) as $status | {
        context: $context,
        state: ($status.state // "missing"),
        updatedAt: ($status.updated_at // $status.created_at // null)
      }] as $contexts
      | {
          state: (
            if any($contexts[]; .state == "failure" or .state == "error") then "red"
            elif all($contexts[]; .state == "success") then "green"
            else "pending"
            end
          ),
          contexts: $contexts,
          failedContexts: [$contexts[] | select(.state == "failure" or .state == "error") | .context],
          pendingContexts: [$contexts[] | select(.state != "success" and .state != "failure" and .state != "error") | .context]
        }
    '
}

ci_gate_poll_github() {
  local required_contexts="$1"
  local revision="$2"
  local timeout="${HCI_CI_GATE_TIMEOUT_SECONDS:-3600}"
  local interval="${HCI_CI_GATE_POLL_INTERVAL_SECONDS:-30}"
  local started attempt=1 body result state

  started="$(date +%s)"
  result='{"state":"api-error","error":"not queried yet","contexts":[],"failedContexts":[],"pendingContexts":[]}'

  while true; do
    if body="$(ci_gate_fetch_github "$revision" 2>&1)" \
      && result="$(ci_gate_eval_github "$body" "$required_contexts" 2>&1)"; then
      ci_gate_event "github-poll" "$(jq -c -n --argjson attempt "$attempt" --argjson github "$result" '{attempt: $attempt, github: $github}')"
      state="$(jq -r '.state' <<< "$result")"
      if [ "$state" = "green" ] || [ "$state" = "red" ]; then
        printf '%s\n' "$result"
        return
      fi
    else
      result="$(jq -c -n --arg error "$body" '{state: "api-error", error: $error, contexts: [], failedContexts: [], pendingContexts: []}')"
      ci_gate_event "github-api-error" "$(jq -c -n --argjson attempt "$attempt" --arg error "$body" '{attempt: $attempt, error: $error}')"
    fi

    if [ $(( $(date +%s) - started )) -ge "$timeout" ]; then
      jq -c -n --argjson github "$result" --argjson timeoutSeconds "$timeout" '$github + {state: "timeout", timeoutSeconds: $timeoutSeconds}'
      return
    fi

    sleep "$interval"
    attempt=$((attempt + 1))
  done
}

ci_gate_hci_curl() {
  local path="$1"
  local token="${HERCULES_CI_API_TOKEN:-${HCI_API_TOKEN:-${HERCULES_CI_TOKEN:-}}}"
  local api_base_url="${HERCULES_CI_API_BASE_URL:-https://hercules-ci.com}"
  local api_url="${HCI_API_URL:-${api_base_url%/}/api/v1}"
  local connect_timeout="${HCI_CI_GATE_CONNECT_TIMEOUT_SECONDS:-10}"
  local max_time="${HCI_CI_GATE_REQUEST_TIMEOUT_SECONDS:-60}"

  if [ -n "${herculesCIHeaders:-}" ] && [ -r "$herculesCIHeaders" ]; then
    curl -fsS --connect-timeout "$connect_timeout" --max-time "$max_time" -H @"$herculesCIHeaders" "${api_url%/}$path"
    return
  fi

  [ "${CI_GATE_HCI_ALLOW_ENV_TOKEN:-false}" = "true" ] || {
    echo "herculesCIHeaders is required for HCI lookup; set CI_GATE_HCI_ALLOW_ENV_TOKEN=true for local env-token fallback" >&2
    return 1
  }
  [ -n "$token" ] || {
    echo "no HCI API token available" >&2
    return 1
  }

  curl -fsS --connect-timeout "$connect_timeout" --max-time "$max_time" -H "Authorization: Bearer $token" "${api_url%/}$path"
}

ci_gate_fetch_hci_latest() {
  local latest="${HCI_CI_GATE_HCI_LATEST_JOBS:-100}"

  if [ -n "${CI_GATE_HCI_JOBS_FILE:-}" ]; then
    [ -r "$CI_GATE_HCI_JOBS_FILE" ] || {
      echo "CI_GATE_HCI_JOBS_FILE is not readable: $CI_GATE_HCI_JOBS_FILE" >&2
      return 1
    }
    cat "$CI_GATE_HCI_JOBS_FILE"
    return
  fi

  ci_gate_hci_curl "/jobs?latest=$latest"
}

ci_gate_fetch_hci_job() {
  local job_id="$1"

  if [ -n "${CI_GATE_HCI_JOB_DETAIL_DIR:-}" ]; then
    local detail_file="$CI_GATE_HCI_JOB_DETAIL_DIR/$job_id.json"
    [ -r "$detail_file" ] || {
      echo "CI_GATE_HCI_JOB_DETAIL_DIR is missing detail file: $detail_file" >&2
      return 1
    }
    cat "$detail_file"
    return
  fi

  ci_gate_hci_curl "/jobs/$job_id"
}

ci_gate_hci_refs() {
  jq -c -n \
    --argjson root "$1" \
    --argjson required "$2" \
    --arg revision "$3" \
    --arg hciProject "${HCI_PROJECT:-github/whitestrake/nixos}" \
    '
      ($hciProject | split("/")) as $project
      | def matching_jobs($name): [
          $root[]? | .project as $p
          | select(($p.siteSlug // "") == $project[0] and ($p.ownerSlug // "") == $project[1] and ($p.slug // "") == $project[2])
          | .jobs[]? | select(.source.revision == $revision and .jobName == $name)
        ] | sort_by(.index // 0, .startTime // "");
      [$required[] as $name | (matching_jobs($name) | last) as $job | select($job != null) | {id: ($job.id | tostring), jobName: $name, summary: $job}]
    '
}

ci_gate_hci_details() {
  local refs="$1"
  local ref job_id job_name summary detail

  while IFS= read -r ref; do
    job_id="$(jq -r '.id' <<< "$ref")"
    job_name="$(jq -r '.jobName' <<< "$ref")"
    summary="$(jq -c '.summary' <<< "$ref")"

    if detail="$(ci_gate_fetch_hci_job "$job_id" 2>&1)" \
      && jq -c -n --argjson summary "$summary" --argjson detail "$detail" '$summary + $detail'; then
      :
    else
      ci_gate_event "hci-detail-error" "$(jq -c -n --arg jobId "$job_id" --arg jobName "$job_name" --arg error "$detail" '{jobId: $jobId, jobName: $jobName, error: $error}')"
      jq -c -n --argjson summary "$summary" --arg error "$detail" '$summary + {detailError: $error}'
    fi
  done < <(jq -c '.[]' <<< "$refs") | jq -s -c '.'
}

ci_gate_eval_hci() {
  jq -c -n \
    --argjson jobs "$1" \
    --argjson required "$2" \
    '
      def failed: (. // "" | tostring | ascii_downcase) | test("fail|error|exception|cancel|timed|abort|unsuccess");
      def success: (. // "" | tostring | ascii_downcase) | test("^(success|succeed|succeeded|successful|done|pass|passed|complete|completed)$");
      def done($job): (($job.jobPhase // "") | tostring | ascii_downcase) == "done";
      def classify($job):
        if $job == null then "missing"
        elif ($job.isCancelled == true) or ([$job.jobStatus, $job.evaluationStatus, $job.derivationStatus, $job.effectsStatus] | map(. // empty) | any(failed)) then "red"
        elif ($job.detailError // null) != null then "unknown"
        elif done($job) and ($job.jobStatus | success) and ([$job.evaluationStatus, $job.derivationStatus, $job.effectsStatus] | map(. // "Success") | all(success)) then "green"
        elif done($job) then "unknown"
        else "pending"
        end;
      def latest($name): [$jobs[]? | select((.jobName // "") == $name)] | sort_by(.index // 0, .startTime // "") | last;
      [$required[] as $name | latest($name) as $job | classify($job) as $class | {
        jobName: $name, found: ($job != null),
        jobPhase: ($job.jobPhase // null), jobStatus: ($job.jobStatus // null),
        evaluationStatus: ($job.evaluationStatus // null), derivationStatus: ($job.derivationStatus // null),
        effectsStatus: ($job.effectsStatus // null), detailError: ($job.detailError // null),
        red: ($class == "red"),
        green: ($class == "green"),
        pending: ($class == "pending")
      }] as $checked
      | {
          state: (
            if any($checked[]; .red) then "red"
            elif all($checked[]; .green) then "green"
            elif any($checked[]; .pending) then "pending"
            else "unknown"
            end
          ),
          jobs: $checked,
          failedJobs: [$checked[] | select(.red) | .jobName],
          missingJobs: [$checked[] | select(.found | not) | .jobName],
          pendingJobs: [$checked[] | select(.pending) | .jobName]
        }
    '
}

ci_gate_poll_hci() {
  local required_jobs="$1"
  local revision="$2"
  local timeout="${HCI_CI_GATE_HCI_TIMEOUT_SECONDS:-${HCI_CI_GATE_TIMEOUT_SECONDS:-3600}}"
  local interval="${HCI_CI_GATE_POLL_INTERVAL_SECONDS:-30}"
  local started attempt=1 body refs details result state

  started="$(date +%s)"

  while true; do
    if ! body="$(ci_gate_fetch_hci_latest 2>&1)"; then
      ci_gate_event "hci-api-error" "$(jq -c -n --argjson attempt "$attempt" --arg error "$body" '{attempt: $attempt, error: $error}')"
      jq -c -n --arg reason "$body" '{state: "unknown", reason: $reason, jobs: [], failedJobs: [], missingJobs: [], pendingJobs: []}'
      return
    fi
    if ! refs="$(ci_gate_hci_refs "$body" "$required_jobs" "$revision" 2>&1)"; then
      ci_gate_event "hci-eval-error" "$(jq -c -n --argjson attempt "$attempt" --arg error "$refs" '{attempt: $attempt, error: $error}')"
      jq -c -n --arg reason "$refs" '{state: "unknown", reason: $reason, jobs: [], failedJobs: [], missingJobs: [], pendingJobs: []}'
      return
    fi

    if ! details="$(ci_gate_hci_details "$refs")"; then
      ci_gate_event "hci-eval-error" "$(jq -c -n --argjson attempt "$attempt" --arg error "failed to assemble HCI job details" '{attempt: $attempt, error: $error}')"
      jq -c -n '{state: "unknown", reason: "failed to assemble HCI job details", jobs: [], failedJobs: [], missingJobs: [], pendingJobs: []}'
      return
    fi
    if ! result="$(ci_gate_eval_hci "$details" "$required_jobs" 2>&1)"; then
      ci_gate_event "hci-eval-error" "$(jq -c -n --argjson attempt "$attempt" --arg error "$result" '{attempt: $attempt, error: $error}')"
      jq -c -n --arg reason "$result" '{state: "unknown", reason: $reason, jobs: [], failedJobs: [], missingJobs: [], pendingJobs: []}'
      return
    fi
    ci_gate_event "hci-poll" "$(jq -c -n --argjson attempt "$attempt" --argjson hci "$result" '{attempt: $attempt, hci: $hci}')"
    state="$(jq -r '.state' <<< "$result")"

    if [ "$state" != "pending" ]; then
      printf '%s\n' "$result"
      return
    fi

    if [ $(( $(date +%s) - started )) -ge "$timeout" ]; then
      jq -c -n --argjson hci "$result" --argjson timeoutSeconds "$timeout" '$hci + {state: "timeout", timeoutSeconds: $timeoutSeconds}'
      return
    fi

    sleep "$interval"
    attempt=$((attempt + 1))
  done
}

run_deployables_ci_gate() {
  local payload="$1"
  local started_at completed_at revision required_jobs required_contexts
  local github github_state hci result config_error

  started_at="$(ci_gate_timestamp)"
  revision="$(jq -r '.rev' <<< "$payload")"
  required_jobs="$(ci_gate_required_jobs "$payload")"
  required_contexts="$(ci_gate_required_contexts "$required_jobs")"

  ci_gate_event "start" "$(jq -c -n --argjson requiredContexts "$required_contexts" --argjson requiredJobNames "$required_jobs" '{requiredContexts: $requiredContexts, requiredJobNames: $requiredJobNames}')"

  if ! config_error="$(ci_gate_validate_config 2>&1)"; then
    github="$(jq -c -n --arg error "$config_error" '{state: "config-error", error: $error, contexts: [], failedContexts: [], pendingContexts: []}')"
    hci='{"state":"skipped","reason":"configuration error","jobs":[],"failedJobs":[],"missingJobs":[],"pendingJobs":[]}'
  else
    github="$(ci_gate_poll_github "$required_contexts" "$revision")"
    github_state="$(jq -r '.state' <<< "$github")"
    if [ "$github_state" = "green" ]; then
      hci="$(ci_gate_poll_hci "$required_jobs" "$revision")"
    else
      hci='{"state":"skipped","reason":"GitHub gate did not pass","jobs":[],"failedJobs":[],"missingJobs":[],"pendingJobs":[]}'
    fi
  fi

  completed_at="$(ci_gate_timestamp)"
  result="$(
    jq -c -n \
      --arg startedAt "$started_at" \
      --arg completedAt "$completed_at" \
      --argjson requiredContexts "$required_contexts" \
      --argjson requiredJobNames "$required_jobs" \
      --argjson github "$github" \
      --argjson hci "$hci" \
      '{
        state: (if $github.state != "green" or $hci.state == "red" or $hci.state == "timeout" then "blocked" else "passed" end),
        startedAt: $startedAt,
        completedAt: $completedAt,
        requiredContexts: $requiredContexts,
        requiredJobNames: $requiredJobNames,
        github: $github,
        hci: $hci,
        warnings: [
          if $hci.state == "unknown" then "HCI cross-check inconclusive: \($hci.reason // "unknown")"
          elif $hci.state == "timeout" then "HCI cross-check timed out while still pending"
          else empty
          end
        ]
      }'
  )"

  if [ "$(jq -r '.hci.state' <<< "$result")" = "unknown" ]; then
    ci_gate_event "hci-warning" "$(jq -c -n --argjson hci "$hci" '{warning: "HCI cross-check inconclusive; proceeding after GitHub gate passed", hci: $hci}')"
  fi

  ci_gate_result "$result"
  printf '%s\n' "$result"
  [ "$(jq -r '.state' <<< "$result")" = "passed" ]
}
