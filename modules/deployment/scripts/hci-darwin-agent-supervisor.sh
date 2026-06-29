#!/usr/bin/env bash
set -euo pipefail

: "${CACHIX_CACHE_NAME:=whitestrake}"
: "${CACHIX_PUBLIC_KEY:=whitestrake.cachix.org-1:UYcyluINGeeyAQgGOrEmOarylMNU5kLMagM0nXOkQK8=}"
: "${DARWIN_CONFIGURATION:=andred}"
: "${GITHUB_API_URL:=https://api.github.com}"
: "${HCI_API_BASE_URL:=https://hercules-ci.com}"
: "${HCI_DARWIN_AGENT_CONCURRENT_TASKS:=1}"
: "${HCI_DARWIN_AGENT_STARTUP_SECONDS:=5}"
: "${HCI_DARWIN_FINISH_CONDITION:=darwin-toplevel}"
: "${HCI_DARWIN_POLL_SECONDS:=30}"
: "${HCI_DARWIN_TIMEOUT_SECONDS:=18000}"
: "${HCI_LATEST_JOBS_LIMIT:=20}"
: "${HCI_PROJECT:=github/whitestrake/nixos}"

log() {
  printf '%s\n' "$*" >&2
}

require_env() {
  local name="$1"

  if [ -z "${!name:-}" ]; then
    log "ERROR: $name is empty."
    exit 1
  fi
}

extract_hci_token() {
  local credentials_json="$1"

  jq -er '.domains."hercules-ci.com".personalToken | select(type == "string" and length > 0)' \
    <<< "$credentials_json"
}

parse_hci_project() {
  IFS=/ read -r HCI_PROJECT_SITE HCI_PROJECT_ACCOUNT HCI_PROJECT_REPO HCI_PROJECT_EXTRA <<< "$HCI_PROJECT"

  if [ -z "${HCI_PROJECT_SITE:-}" ] \
    || [ -z "${HCI_PROJECT_ACCOUNT:-}" ] \
    || [ -z "${HCI_PROJECT_REPO:-}" ] \
    || [ -n "${HCI_PROJECT_EXTRA:-}" ]; then
    log "ERROR: HCI_PROJECT must have the form site/account/project, got: $HCI_PROJECT"
    exit 1
  fi
}

find_hci_job_id_for_revision() {
  local jobs_json="$1"
  local revision="$2"
  local job_name

  job_name="$(hci_darwin_job_name)"

  jq -er \
    --arg revision "$revision" \
    --arg site "$HCI_PROJECT_SITE" \
    --arg account "$HCI_PROJECT_ACCOUNT" \
    --arg repo "$HCI_PROJECT_REPO" \
    --arg jobName "$job_name" \
    '
      [
        .[]?
        | select(.project.siteSlug == $site)
        | select(.project.ownerSlug == $account)
        | select(.project.slug == $repo)
        | .jobs[]?
        | select(.source.revision == $revision)
        | select(.jobName == $jobName)
        | .id
      ][0] // empty
    ' <<< "$jobs_json"
}

hci_darwin_job_name() {
  printf '10-darwinConfiguration-%s\n' "$DARWIN_CONFIGURATION"
}

hci_github_status_context() {
  printf 'ci/hercules/onPush/%s\n' "$(hci_darwin_job_name)"
}

github_repository() {
  printf '%s\n' "${GITHUB_REPOSITORY:-$HCI_PROJECT_ACCOUNT/$HCI_PROJECT_REPO}"
}

find_hci_job_index_for_revision_statuses() {
  local statuses_json="$1"
  local revision="$2"
  local context

  context="$(hci_github_status_context)"

  jq -er \
    --arg context "$context" \
    --arg revision "$revision" \
    '
      [
        .[]?
        | select(.context == $context)
        | select((.target_url? // "") | test("/jobs/[0-9]+$"))
        | {
            state: (.state // ""),
            updatedAt: (.updated_at // .created_at // ""),
            index: (.target_url | capture("/jobs/(?<index>[0-9]+)$").index)
          }
      ]
      | sort_by(.updatedAt)
      | last
      | .index // empty
    ' <<< "$statuses_json"
}

find_hci_job_id_for_index() {
  local jobs_json="$1"
  local index="$2"
  local revision="$3"
  local job_name

  job_name="$(hci_darwin_job_name)"

  jq -er \
    --arg index "$index" \
    --arg revision "$revision" \
    --arg site "$HCI_PROJECT_SITE" \
    --arg account "$HCI_PROJECT_ACCOUNT" \
    --arg repo "$HCI_PROJECT_REPO" \
    --arg jobName "$job_name" \
    '
      [
        .[]? as $group
        | $group.jobs[]?
        | select((.index | tostring) == $index)
        | select(.source.revision == $revision)
        | select(.jobName == $jobName)
        | select(((.forgeName // $group.project.siteSlug // "") == $site))
        | select(((.ownerName // $group.project.ownerSlug // "") == $account))
        | select(((.repoName // $group.project.slug // "") == $repo))
        | .id
      ][0] // empty
    ' <<< "$jobs_json"
}

classify_hci_job() {
  local job_json="$1"

  jq -er '
    def lower_statuses:
      [
        .jobStatus?,
        .evaluationStatus?,
        .derivationStatus?,
        .effectsStatus?
      ]
      | map(select(. != null) | tostring | ascii_downcase);

    lower_statuses as $statuses
    | (.jobPhase? // "" | tostring | ascii_downcase) as $phase
    | if any($statuses[]; test("fail|error|exception|cancel|timed|abort|unsuccess")) then
        "failure"
      elif $phase == "done" then
        if (($statuses | length) > 0 and all($statuses[]; test("^(success|succeed|succeeded|successful|done|pass|passed|complete|completed)"))) then
          "success"
        else
          "unknown"
        end
      else
        "running"
      end
  ' <<< "$job_json"
}

should_wait_for_hci_job_done() {
  case "$HCI_DARWIN_FINISH_CONDITION" in
    darwin-toplevel)
      return 1
      ;;
    hci-job-done)
      return 0
      ;;
    *)
      log "ERROR: HCI_DARWIN_FINISH_CONDITION must be darwin-toplevel or hci-job-done, got: $HCI_DARWIN_FINISH_CONDITION"
      exit 1
      ;;
  esac
}

emit_job_status() {
  local job_json="$1"

  jq '{jobPhase, jobStatus, evaluationStatus, derivationStatus, effectsStatus}' <<< "$job_json" >&2 || true
}

hci_api_get() {
  local path="$1"

  curl -fsS \
    --connect-timeout 10 \
    --max-time 60 \
    --retry 3 \
    --retry-delay 2 \
    --retry-all-errors \
    -H "Authorization: Bearer $HCI_API_TOKEN" \
    "$HCI_API_BASE_URL$path"
}

github_api_get() {
  local path="$1"
  local curl_args=(
    curl -fsS
    --connect-timeout 10
    --max-time 60
    --retry 3
    --retry-delay 2
    --retry-all-errors
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi

  "${curl_args[@]}" "$GITHUB_API_URL$path"
}

find_hci_job_id_for_revision_status() {
  local revision="$1"
  local repository statuses_json job_index jobs_json job_id

  if [ "$HCI_PROJECT_SITE" != "github" ]; then
    return 1
  fi

  repository="$(github_repository)"

  if ! statuses_json="$(github_api_get "/repos/$repository/commits/$revision/statuses?per_page=100")"; then
    log "WARNING: failed to fetch GitHub commit statuses for $repository revision $revision."
    return 1
  fi

  if ! job_index="$(find_hci_job_index_for_revision_statuses "$statuses_json" "$revision")" || [ -z "$job_index" ]; then
    return 1
  fi

  if ! jobs_json="$(hci_api_get "/api/v1/jobs?index=$job_index")"; then
    log "WARNING: failed to fetch Hercules CI job index $job_index from GitHub status target."
    return 1
  fi

  if ! job_id="$(find_hci_job_id_for_index "$jobs_json" "$job_index" "$revision")" || [ -z "$job_id" ]; then
    log "WARNING: GitHub status target referenced Hercules CI job index $job_index, but it did not match $HCI_PROJECT revision $revision."
    return 1
  fi

  log "Found Hercules CI job $job_id from GitHub status target jobs/$job_index."
  printf '%s\n' "$job_id"
}

write_agent_files() {
  local old_umask

  require_env RUNNER_TEMP
  require_env HERCULES_CI_CLUSTER_JOIN_TOKEN
  require_env HERCULES_CI_CREDENTIALS_JSON
  require_env CACHIX_AUTH_TOKEN

  old_umask="$(umask)"
  umask 077

  HCI_DARWIN_WORK_DIR="$RUNNER_TEMP/hci-darwin-agent"
  HCI_AGENT_BASE_DIR="$HCI_DARWIN_WORK_DIR/agent"
  HCI_AGENT_SECRET_STATE_DIR="$HCI_AGENT_BASE_DIR/secretState"
  HCI_AGENT_SECRETS_DIR="$HCI_DARWIN_WORK_DIR/secrets"
  HCI_AGENT_CONFIG_FILE="$HCI_DARWIN_WORK_DIR/agent.json"
  HCI_AGENT_CLUSTER_JOIN_FILE="$HCI_AGENT_SECRETS_DIR/cluster-join-token.key"
  HCI_AGENT_BINARY_CACHES_FILE="$HCI_AGENT_SECRETS_DIR/binary-caches.json"
  HCI_AGENT_SECRETS_FILE="$HCI_AGENT_SECRETS_DIR/secrets.json"

  mkdir -p "$HCI_AGENT_BASE_DIR" "$HCI_AGENT_SECRET_STATE_DIR" "$HCI_AGENT_SECRETS_DIR"
  chmod 700 "$HCI_DARWIN_WORK_DIR" "$HCI_AGENT_BASE_DIR" "$HCI_AGENT_SECRET_STATE_DIR" "$HCI_AGENT_SECRETS_DIR"

  printf '%s' "$HERCULES_CI_CLUSTER_JOIN_TOKEN" > "$HCI_AGENT_CLUSTER_JOIN_FILE"
  chmod 600 "$HCI_AGENT_CLUSTER_JOIN_FILE"

  jq -n \
    --arg cacheName "$CACHIX_CACHE_NAME" \
    --arg authToken "$CACHIX_AUTH_TOKEN" \
    --arg publicKey "$CACHIX_PUBLIC_KEY" \
    '{
      ($cacheName): {
        kind: "CachixCache",
        authToken: $authToken,
        publicKeys: [$publicKey],
        signingKeys: []
      }
    }' > "$HCI_AGENT_BINARY_CACHES_FILE"
  chmod 600 "$HCI_AGENT_BINARY_CACHES_FILE"

  jq -n '{}' > "$HCI_AGENT_SECRETS_FILE"
  chmod 600 "$HCI_AGENT_SECRETS_FILE"

  jq -n \
    --arg baseDirectory "$HCI_AGENT_BASE_DIR" \
    --arg clusterJoinTokenPath "$HCI_AGENT_CLUSTER_JOIN_FILE" \
    --arg binaryCachesPath "$HCI_AGENT_BINARY_CACHES_FILE" \
    --arg secretsJsonPath "$HCI_AGENT_SECRETS_FILE" \
    --argjson concurrentTasks "$HCI_DARWIN_AGENT_CONCURRENT_TASKS" \
    '{
      baseDirectory: $baseDirectory,
      clusterJoinTokenPath: $clusterJoinTokenPath,
      binaryCachesPath: $binaryCachesPath,
      secretsJsonPath: $secretsJsonPath,
      nixUserIsTrusted: true,
      concurrentTasks: $concurrentTasks,
      nixVerbosity: "Talkative",
      logLevel: "InfoS"
    }' > "$HCI_AGENT_CONFIG_FILE"
  chmod 600 "$HCI_AGENT_CONFIG_FILE"

  umask "$old_umask"
}

cleanup_agent_files() {
  if [ -z "${HCI_DARWIN_WORK_DIR:-}" ] || [ -z "${RUNNER_TEMP:-}" ]; then
    return 0
  fi

  case "$HCI_DARWIN_WORK_DIR" in
    "$RUNNER_TEMP"/hci-darwin-agent)
      rm -rf "$HCI_DARWIN_WORK_DIR"
      ;;
    *)
      log "WARNING: refusing to remove unexpected work directory: $HCI_DARWIN_WORK_DIR"
      ;;
  esac
}

start_agent() {
  require_env HCI_AGENT_CONFIG_FILE

  if ! command -v hercules-ci-agent >/dev/null 2>&1; then
    log "ERROR: hercules-ci-agent is not in PATH."
    exit 1
  fi

  log "Starting ephemeral Hercules CI Darwin agent..."
  env \
    -u CACHIX_AUTH_TOKEN \
    -u HERCULES_CI_CLUSTER_JOIN_TOKEN \
    -u HERCULES_CI_CREDENTIALS_JSON \
    -u HCI_API_TOKEN \
    hercules-ci-agent --config "$HCI_AGENT_CONFIG_FILE" &
  HCI_AGENT_PID="$!"

  sleep "$HCI_DARWIN_AGENT_STARTUP_SECONDS"
  if ! kill -0 "$HCI_AGENT_PID" 2>/dev/null; then
    wait "$HCI_AGENT_PID" 2>/dev/null || true
    log "ERROR: hercules-ci-agent exited during startup."
    exit 1
  fi

  log "Hercules CI agent is running as PID $HCI_AGENT_PID."
}

stop_agent() {
  local pid="${HCI_AGENT_PID:-}"

  if [ -z "$pid" ]; then
    return 0
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    return 0
  fi

  log "Stopping Hercules CI agent PID $pid..."
  kill "$pid" 2>/dev/null || true

  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 1
  done

  log "Agent did not exit after TERM; killing PID $pid."
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local status=$?

  trap - EXIT
  stop_agent
  cleanup_agent_files
  exit "$status"
}

wait_for_job_id() {
  local revision="$1"
  local deadline="$2"
  local jobs_json job_id

  if [ -n "${HCI_JOB_ID:-}" ]; then
    printf '%s\n' "$HCI_JOB_ID"
    return 0
  fi

  while [ "$SECONDS" -lt "$deadline" ]; do
    if job_id="$(find_hci_job_id_for_revision_status "$revision")" && [ -n "$job_id" ]; then
      printf '%s\n' "$job_id"
      return 0
    fi

    if ! jobs_json="$(hci_api_get "/api/v1/jobs?latest=$HCI_LATEST_JOBS_LIMIT")"; then
      log "WARNING: failed to fetch latest Hercules CI jobs; retrying."
      sleep "$HCI_DARWIN_POLL_SECONDS"
      continue
    fi

    if job_id="$(find_hci_job_id_for_revision "$jobs_json" "$revision")" && [ -n "$job_id" ]; then
      printf '%s\n' "$job_id"
      return 0
    fi

    log "Waiting for Hercules CI job for $HCI_PROJECT revision $revision..."
    sleep "$HCI_DARWIN_POLL_SECONDS"
  done

  log "ERROR: timed out waiting for Hercules CI job for $HCI_PROJECT revision $revision."
  return 1
}

prepare_darwin_toplevel() {
  DARWIN_TOPLEVEL_ATTR=".#darwinConfigurations.${DARWIN_CONFIGURATION}.config.system.build.toplevel"

  log "Evaluating Darwin toplevel path for $DARWIN_CONFIGURATION..."
  if ! DARWIN_TOPLEVEL_OUT_PATH="$(nix eval --accept-flake-config --raw "$DARWIN_TOPLEVEL_ATTR.outPath")"; then
    log "ERROR: could not evaluate $DARWIN_TOPLEVEL_ATTR.outPath."
    return 1
  fi

  DARWIN_GCROOT_DIR="${HCI_DARWIN_GCROOT_DIR:-/nix/var/nix/gcroots/hci-darwin-agent}"
  DARWIN_GCROOT_LINK="$DARWIN_GCROOT_DIR/$DARWIN_CONFIGURATION"
}

try_root_darwin_toplevel() {
  if [ -z "${DARWIN_TOPLEVEL_OUT_PATH:-}" ] \
    || [ -z "${DARWIN_TOPLEVEL_ATTR:-}" ] \
    || [ -z "${DARWIN_GCROOT_DIR:-}" ] \
    || [ -z "${DARWIN_GCROOT_LINK:-}" ]; then
    log "ERROR: Darwin toplevel root state is not initialised."
    return 1
  fi

  if ! mkdir -p "$DARWIN_GCROOT_DIR" 2>/dev/null; then
    if nix path-info "$DARWIN_TOPLEVEL_OUT_PATH" >/dev/null 2>&1; then
      log "WARNING: Darwin toplevel is local, but $DARWIN_GCROOT_DIR is not writable; cache root finalization skipped."
      return 0
    fi

    log "WARNING: $DARWIN_GCROOT_DIR is not writable yet and Darwin toplevel is not local."
    return 1
  fi

  if nix path-info "$DARWIN_TOPLEVEL_OUT_PATH" >/dev/null 2>&1; then
    if ln -sfn "$DARWIN_TOPLEVEL_OUT_PATH" "$DARWIN_GCROOT_LINK"; then
      log "Rooted existing Darwin toplevel: $DARWIN_GCROOT_LINK -> $DARWIN_TOPLEVEL_OUT_PATH"
    else
      log "WARNING: Darwin toplevel is local, but $DARWIN_GCROOT_LINK could not be updated; cache root finalization skipped."
    fi
    return 0
  fi

  log "Darwin toplevel is not local; attempting substitute-only realisation for cache root..."
  if nix build \
    --accept-flake-config \
    --option max-jobs 0 \
    --out-link "$DARWIN_GCROOT_LINK" \
    "$DARWIN_TOPLEVEL_ATTR"; then
    log "Rooted substituted Darwin toplevel: $DARWIN_GCROOT_LINK"
    return 0
  fi

  if nix path-info "$DARWIN_TOPLEVEL_OUT_PATH" >/dev/null 2>&1; then
    log "WARNING: Darwin toplevel became local, but cache root finalization failed."
    return 0
  fi

  return 1
}

emit_local_darwin_toplevel_ready() {
  log "LOCAL_DARWIN_BUILD_COMPLETE configuration=$DARWIN_CONFIGURATION outPath=$DARWIN_TOPLEVEL_OUT_PATH gcroot=$DARWIN_GCROOT_LINK"
}

monitor_darwin_toplevel() {
  local job_id="$1"
  local deadline="$2"
  local darwin_toplevel_available=0
  local job_json status
  local wait_for_hci_job_done=0

  if should_wait_for_hci_job_done; then
    wait_for_hci_job_done=1
  fi

  log "Monitoring Hercules CI job $job_id while waiting for $DARWIN_TOPLEVEL_OUT_PATH."
  log "Note: sortie may still satisfy Darwin work; this workflow proves additive Darwin capacity and toplevel availability, not exclusive GitHub-builder execution."

  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$darwin_toplevel_available" -eq 0 ] && try_root_darwin_toplevel; then
      darwin_toplevel_available=1
      emit_local_darwin_toplevel_ready
      log "Darwin toplevel for $DARWIN_CONFIGURATION is available."
      if [ "$wait_for_hci_job_done" -eq 0 ]; then
        return 0
      fi
    fi

    if ! job_json="$(hci_api_get "/api/v1/jobs/$job_id")"; then
      log "WARNING: failed to fetch Hercules CI job $job_id; retrying."
      sleep "$HCI_DARWIN_POLL_SECONDS"
      continue
    fi

    if ! status="$(classify_hci_job "$job_json")"; then
      log "ERROR: could not classify Hercules CI job $job_id."
      emit_job_status "$job_json"
      return 1
    fi

    case "$status" in
      failure)
        if [ "$darwin_toplevel_available" -eq 1 ]; then
          log "ERROR: Hercules CI job $job_id failed after Darwin toplevel became available."
        else
          log "ERROR: Hercules CI job $job_id failed before Darwin toplevel became available."
        fi
        emit_job_status "$job_json"
        return 1
        ;;
      success)
        if [ "$darwin_toplevel_available" -eq 1 ] || try_root_darwin_toplevel; then
          if [ "$darwin_toplevel_available" -eq 0 ]; then
            darwin_toplevel_available=1
            emit_local_darwin_toplevel_ready
          fi
          log "Hercules CI job $job_id completed successfully and Darwin toplevel for $DARWIN_CONFIGURATION is available."
          return 0
        fi

        log "ERROR: Hercules CI job $job_id completed, but Darwin toplevel is still unavailable via substitute-only realisation."
        emit_job_status "$job_json"
        return 1
        ;;
      unknown)
        log "ERROR: Hercules CI job $job_id is done, but status fields are absent or not success-like."
        emit_job_status "$job_json"
        return 1
        ;;
      running)
        if [ "$darwin_toplevel_available" -eq 1 ]; then
          log "Hercules CI job $job_id is still active; Darwin toplevel is available."
        else
          log "Hercules CI job $job_id is still active; Darwin toplevel is not available yet."
        fi
        ;;
      *)
        log "ERROR: unexpected Hercules CI job status classification: $status"
        return 1
        ;;
    esac

    sleep "$HCI_DARWIN_POLL_SECONDS"
  done

  if [ "$darwin_toplevel_available" -eq 1 ]; then
    log "ERROR: timed out waiting for Hercules CI job $job_id to finish."
  else
    log "ERROR: timed out waiting for Darwin toplevel for $DARWIN_CONFIGURATION."
  fi
  return 1
}

main() {
  local deadline job_id revision

  require_env HERCULES_CI_CREDENTIALS_JSON

  revision="${HCI_REVISION:-${GITHUB_SHA:-}}"
  if [ -z "$revision" ]; then
    log "ERROR: HCI_REVISION or GITHUB_SHA must be set."
    exit 1
  fi

  if [ -n "${GITHUB_SHA:-}" ] && [ "$revision" != "$GITHUB_SHA" ]; then
    log "WARNING: HCI_REVISION differs from the checked-out GITHUB_SHA; Darwin toplevel evaluation uses the local checkout."
    log "  HCI_REVISION: $revision"
    log "  GITHUB_SHA:   $GITHUB_SHA"
  fi

  parse_hci_project
  HCI_API_TOKEN="$(extract_hci_token "$HERCULES_CI_CREDENTIALS_JSON")"
  deadline=$((SECONDS + HCI_DARWIN_TIMEOUT_SECONDS))

  write_agent_files
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  prepare_darwin_toplevel
  start_agent

  if try_root_darwin_toplevel; then
    emit_local_darwin_toplevel_ready
    log "Darwin toplevel for $DARWIN_CONFIGURATION is available before HCI job discovery."
    if ! should_wait_for_hci_job_done; then
      return 0
    fi
  fi

  job_id="$(wait_for_job_id "$revision" "$deadline")"
  monitor_darwin_toplevel "$job_id" "$deadline"
}

if [ "${HCI_DARWIN_SUPERVISOR_LIB_ONLY:-}" != "1" ]; then
  main "$@"
fi
