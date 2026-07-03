#!/usr/bin/env bash
set -euo pipefail

: "${CACHIX_CACHE_NAME:=whitestrake}"
: "${CACHIX_PUBLIC_KEY:=whitestrake.cachix.org-1:UYcyluINGeeyAQgGOrEmOarylMNU5kLMagM0nXOkQK8=}"
: "${GITHUB_API_URL:=https://api.github.com}"
: "${HCI_AGENT_CONCURRENT_TASKS:=1}"
: "${HCI_AGENT_HOSTNAME:=}"
: "${HCI_AGENT_JOB_DISCOVERY_SECONDS:=60}"
: "${HCI_AGENT_JOB_NAME:=}"
: "${HCI_AGENT_JOB_NAME_FILE:=}"
: "${HCI_AGENT_JOB_NAME_WAIT_SECONDS:=600}"
: "${HCI_AGENT_POLL_SECONDS:=30}"
: "${HCI_AGENT_READY_TARGET_ATTR:=}"
: "${HCI_AGENT_READY_TARGET_NAME:=}"
: "${HCI_AGENT_STARTUP_SECONDS:=5}"
: "${HCI_AGENT_TIMEOUT_SECONDS:=18000}"
: "${HCI_AGENT_TOOLS_BOOTSTRAPPED:=0}"
: "${HCI_AGENT_TOOLS_GCROOT_DIR:=/nix/var/nix/gcroots/hci-agent-supervisor/tools}"
: "${HCI_API_BASE_URL:=https://hercules-ci.com}"
: "${HCI_LATEST_JOBS_LIMIT:=20}"
: "${HCI_PROJECT:=github/whitestrake/nixos}"

log() {
  printf '%s\n' "$*" >&2
}

notice() {
  printf '::notice title=Hercules CI job unavailable::%s\n' "$*"
}

emit_job_found_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'job-found=%s\n' "$1" >> "$GITHUB_OUTPUT"
  fi
}

require_env() {
  local name="$1"

  if [ -z "${!name:-}" ]; then
    log "ERROR: $name is empty."
    exit 1
  fi
}

require_positive_integer() {
  local name="$1"
  local value="${!name:-}"

  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    log "ERROR: $name must be a positive integer, got: $value"
    exit 1
  fi
}

hci_agent_rooted_tools_available() {
  local tool

  for tool in curl jq hercules-ci-agent; do
    [ -x "$HCI_AGENT_TOOLS_GCROOT_DIR/$tool/bin/$tool" ] || return 1
  done
}

prepend_hci_agent_tool_path() {
  PATH="$HCI_AGENT_TOOLS_GCROOT_DIR/curl/bin:$HCI_AGENT_TOOLS_GCROOT_DIR/jq/bin:$HCI_AGENT_TOOLS_GCROOT_DIR/hercules-ci-agent/bin:$PATH"
  export PATH
}

hci_agent_tools_in_path() {
  local tool

  for tool in curl jq hercules-ci-agent; do
    command -v "$tool" >/dev/null 2>&1 || return 1
  done
}

bootstrap_hci_agent_tools() {
  if [ "${HCI_AGENT_SUPERVISOR_LIB_ONLY:-}" = "1" ]; then
    return 0
  fi

  if hci_agent_rooted_tools_available; then
    prepend_hci_agent_tool_path
    log "Using persisted HCI agent tools from $HCI_AGENT_TOOLS_GCROOT_DIR."
    return 0
  fi

  if [ "$HCI_AGENT_TOOLS_BOOTSTRAPPED" = "1" ]; then
    if hci_agent_tools_in_path; then
      return 0
    fi

    log "ERROR: required HCI agent tools are still unavailable after nix shell fallback."
    exit 1
  fi

  log "Persisted HCI agent tools are incomplete; entering nix shell fallback."
  HCI_AGENT_TOOLS_BOOTSTRAPPED=1 exec nix shell \
    --accept-flake-config \
    --inputs-from . \
    nixpkgs#curl \
    nixpkgs#hercules-ci-agent \
    nixpkgs#jq \
    -c bash "$0" "$@"

  log "ERROR: failed to exec nix shell fallback."
  exit 1
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

hci_job_name_from_file() {
  local deadline job_name path

  path="$HCI_AGENT_JOB_NAME_FILE"
  require_positive_integer HCI_AGENT_JOB_NAME_WAIT_SECONDS

  deadline=$((SECONDS + HCI_AGENT_JOB_NAME_WAIT_SECONDS))
  log "Waiting for HCI job name file: $path"

  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -s "$path" ]; then
      IFS= read -r job_name < "$path" || true
      if [ -n "$job_name" ]; then
        printf '%s\n' "$job_name"
        return 0
      fi
    fi

    if [ -e "$path.failed" ]; then
      log "ERROR: HCI job name resolver failed."
      return 1
    fi

    sleep 1
  done

  log "ERROR: timed out waiting for HCI job name file: $path"
  return 1
}

hci_job_name() {
  if [ -n "${HCI_AGENT_JOB_NAME:-}" ]; then
    printf '%s\n' "$HCI_AGENT_JOB_NAME"
  elif [ -n "${HCI_AGENT_JOB_NAME_FILE:-}" ]; then
    hci_job_name_from_file
  else
    log "ERROR: set HCI_AGENT_JOB_NAME or HCI_AGENT_JOB_NAME_FILE."
    return 1
  fi
}

resolve_final_gate_job_name() {
  local nix_pid tmp watchdog_pid

  tmp="${HCI_AGENT_JOB_NAME_FILE}.$$"
  rm -f "$HCI_AGENT_JOB_NAME_FILE" "$HCI_AGENT_JOB_NAME_FILE.failed" "$tmp"

  nix eval --accept-flake-config --raw .#herculesCI --apply '
    herculesCI:
      let
        hci = herculesCI {
          primaryRepo = {
            branch = "master";
            ref = "refs/heads/master";
            rev = "0000000000000000000000000000000000000000";
            shortRev = "0000000";
          };
          herculesCI = {};
        };
        effectJobNames =
          builtins.filter
          (name: ((builtins.getAttr name hci.onPush).outputs.effects or {}) != {})
          (builtins.attrNames hci.onPush);
      in builtins.elemAt effectJobNames ((builtins.length effectJobNames) - 1)
  ' > "$tmp" &
  nix_pid="$!"

  (
    sleep "$HCI_AGENT_JOB_NAME_WAIT_SECONDS"
    if kill -0 "$nix_pid" 2>/dev/null; then
      kill "$nix_pid" 2>/dev/null || true
      : > "$HCI_AGENT_JOB_NAME_FILE.failed"
    fi
  ) &
  watchdog_pid="$!"

  trap 'kill "$nix_pid" "$watchdog_pid" 2>/dev/null || true; rm -f "$tmp"' EXIT
  trap 'kill "$nix_pid" "$watchdog_pid" 2>/dev/null || true; rm -f "$tmp"; exit 143' TERM INT

  if wait "$nix_pid" && [ -s "$tmp" ]; then
    kill "$watchdog_pid" 2>/dev/null || true
    mv "$tmp" "$HCI_AGENT_JOB_NAME_FILE"
    printf 'HCI_FINAL_GATE_JOB_NAME=%s\n' "$(cat "$HCI_AGENT_JOB_NAME_FILE")"
  else
    kill "$watchdog_pid" 2>/dev/null || true
    rm -f "$tmp"
    : > "$HCI_AGENT_JOB_NAME_FILE.failed"
    return 1
  fi
}

start_final_gate_job_name_resolver() {
  if [ -n "${HCI_AGENT_JOB_NAME:-}" ] || [ -z "${HCI_AGENT_JOB_NAME_FILE:-}" ]; then
    return 0
  fi

  require_positive_integer HCI_AGENT_JOB_NAME_WAIT_SECONDS

  resolve_final_gate_job_name &
  HCI_AGENT_JOB_NAME_RESOLVER_PID="$!"
}

stop_final_gate_job_name_resolver() {
  local pid="${HCI_AGENT_JOB_NAME_RESOLVER_PID:-}"

  if [ -z "$pid" ]; then
    return 0
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  HCI_AGENT_JOB_NAME_RESOLVER_PID=""
}

hci_github_status_context() {
  local job_name

  job_name="$(hci_job_name)" || return 1
  printf 'ci/hercules/onPush/%s\n' "$job_name"
}

github_repository() {
  printf '%s\n' "${GITHUB_REPOSITORY:-$HCI_PROJECT_ACCOUNT/$HCI_PROJECT_REPO}"
}

find_hci_job_id_for_revision() {
  local jobs_json="$1"
  local revision="$2"
  local job_name

  job_name="$(hci_job_name)"

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

  job_name="$(hci_job_name)"

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

set_agent_hostname() {
  if [ -z "$HCI_AGENT_HOSTNAME" ]; then
    return 0
  fi

  log "Setting HCI agent hostname to $HCI_AGENT_HOSTNAME."

  if command -v scutil >/dev/null 2>&1; then
    sudo scutil --set HostName "$HCI_AGENT_HOSTNAME"
    sudo scutil --set LocalHostName "$HCI_AGENT_HOSTNAME"
  elif command -v hostnamectl >/dev/null 2>&1; then
    sudo hostnamectl set-hostname "$HCI_AGENT_HOSTNAME"
  fi

  sudo hostname "$HCI_AGENT_HOSTNAME"
  hostname
}

write_agent_files() {
  local old_umask

  require_env RUNNER_TEMP
  require_env HERCULES_CI_CLUSTER_JOIN_TOKEN
  require_env HERCULES_CI_CREDENTIALS_JSON
  require_env CACHIX_AUTH_TOKEN
  require_positive_integer HCI_AGENT_CONCURRENT_TASKS

  old_umask="$(umask)"
  umask 077

  HCI_AGENT_WORK_DIR="$RUNNER_TEMP/hci-agent-supervisor"
  HCI_AGENT_BASE_DIR="$HCI_AGENT_WORK_DIR/agent"
  HCI_AGENT_SECRET_STATE_DIR="$HCI_AGENT_BASE_DIR/secretState"
  HCI_AGENT_SECRETS_DIR="$HCI_AGENT_WORK_DIR/secrets"
  HCI_AGENT_CONFIG_FILE="$HCI_AGENT_WORK_DIR/agent.json"
  HCI_AGENT_CLUSTER_JOIN_FILE="$HCI_AGENT_SECRETS_DIR/cluster-join-token.key"
  HCI_AGENT_BINARY_CACHES_FILE="$HCI_AGENT_SECRETS_DIR/binary-caches.json"
  HCI_AGENT_SECRETS_FILE="$HCI_AGENT_SECRETS_DIR/secrets.json"
  mkdir -p "$HCI_AGENT_BASE_DIR" "$HCI_AGENT_SECRET_STATE_DIR" "$HCI_AGENT_SECRETS_DIR"
  chmod 700 "$HCI_AGENT_WORK_DIR" "$HCI_AGENT_BASE_DIR" "$HCI_AGENT_SECRET_STATE_DIR" "$HCI_AGENT_SECRETS_DIR"

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
    --argjson concurrentTasks "$HCI_AGENT_CONCURRENT_TASKS" \
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
  if [ -z "${HCI_AGENT_WORK_DIR:-}" ] || [ -z "${RUNNER_TEMP:-}" ]; then
    return 0
  fi

  case "$HCI_AGENT_WORK_DIR" in
    "$RUNNER_TEMP"/hci-agent-supervisor)
      rm -rf "$HCI_AGENT_WORK_DIR"
      ;;
    *)
      log "WARNING: refusing to remove unexpected work directory: $HCI_AGENT_WORK_DIR"
      ;;
  esac
}

start_agent() {
  require_env HCI_AGENT_CONFIG_FILE

  if ! command -v hercules-ci-agent >/dev/null 2>&1; then
    log "ERROR: hercules-ci-agent is not in PATH."
    exit 1
  fi

  log "Starting ephemeral Hercules CI agent..."
  env \
    -u CACHIX_AUTH_TOKEN \
    -u GITHUB_TOKEN \
    -u HERCULES_CI_CLUSTER_JOIN_TOKEN \
    -u HERCULES_CI_CREDENTIALS_JSON \
    -u HCI_API_TOKEN \
    hercules-ci-agent --config "$HCI_AGENT_CONFIG_FILE" &
  HCI_AGENT_PID="$!"

  sleep "$HCI_AGENT_STARTUP_SECONDS"
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
    HCI_AGENT_PID=""
    return 0
  fi

  log "Stopping Hercules CI agent PID $pid..."
  kill "$pid" 2>/dev/null || true

  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      HCI_AGENT_PID=""
      return 0
    fi
    sleep 1
  done

  log "Agent did not exit after TERM; killing PID $pid."
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  HCI_AGENT_PID=""
}

agent_worker_processes() {
  local pid="${HCI_AGENT_PID:-}"

  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  ps -axo pid=,ppid=,command= 2>/dev/null \
    | awk -v root="$pid" '
      {
        pid = $1
        ppid = $2
        $1 = ""
        $2 = ""
        sub(/^[[:space:]]+/, "", $0)
        parent[pid] = ppid
        command[pid] = $0
      }
      END {
        for (pid in command) {
          if (command[pid] !~ /hercules-ci-agent-worker/) {
            continue
          }

          ancestor = pid
          while (ancestor in parent && ancestor != "0") {
            if (ancestor == root) {
              print pid "\t" command[pid]
              break
            }
            ancestor = parent[ancestor]
          }
        }
      }
    '
}

wait_for_agent_workers_on_failure() {
  local status="$1"
  local workers

  case "$status" in
    0 | 130 | 143)
      return 0
      ;;
  esac

  while workers="$(agent_worker_processes)" && [ -n "$workers" ]; do
    log "Hercules CI agent has active workers:"
    log "$workers"
    log "Supervisor is failing, but Hercules CI workers are active; keeping agent online."
    sleep "$HCI_AGENT_POLL_SECONDS"
  done
}

cleanup() {
  local status=$?

  trap - EXIT
  stop_final_gate_job_name_resolver
  wait_for_agent_workers_on_failure "$status"
  stop_agent
  cleanup_agent_files
  exit "$status"
}

wait_for_job_id() {
  local revision="$1"
  local deadline="$2"
  local job_discovery_deadline="$3"
  local jobs_json job_id

  HCI_AGENT_JOB_NAME="$(hci_job_name)" || return 1
  export HCI_AGENT_JOB_NAME

  while [ "$SECONDS" -lt "$deadline" ] && [ "$SECONDS" -lt "$job_discovery_deadline" ]; do
    if job_id="$(find_hci_job_id_for_revision_status "$revision")" && [ -n "$job_id" ]; then
      printf '%s\n' "$job_id"
      return 0
    fi

    if ! jobs_json="$(hci_api_get "/api/v1/jobs?latest=$HCI_LATEST_JOBS_LIMIT")"; then
      log "WARNING: failed to fetch latest Hercules CI jobs; retrying."
      sleep "$HCI_AGENT_POLL_SECONDS"
      continue
    fi

    if job_id="$(find_hci_job_id_for_revision "$jobs_json" "$revision")" && [ -n "$job_id" ]; then
      printf '%s\n' "$job_id"
      return 0
    fi

    log "Waiting for Hercules CI job $HCI_AGENT_JOB_NAME for $HCI_PROJECT revision $revision..."
    sleep "$HCI_AGENT_POLL_SECONDS"
  done

  if [ "$SECONDS" -ge "$job_discovery_deadline" ]; then
    log "No Hercules CI job appeared for $HCI_PROJECT revision $revision within ${HCI_AGENT_JOB_DISCOVERY_SECONDS}s."
    return 2
  fi

  log "ERROR: timed out waiting for Hercules CI job for $HCI_PROJECT revision $revision."
  return 1
}

validate_target_name() {
  local name="$1"

  case "$name" in
    "" | *[!A-Za-z0-9._-]*)
      log "ERROR: unsafe ready target name for gcroot path: $name"
      return 1
      ;;
  esac
}

validate_ready_target() {
  require_env HCI_AGENT_READY_TARGET_NAME
  require_env HCI_AGENT_READY_TARGET_ATTR
  validate_target_name "$HCI_AGENT_READY_TARGET_NAME"
}

prepare_ready_target() {
  log "Evaluating ready target path for $HCI_AGENT_READY_TARGET_NAME..."
  if ! HCI_AGENT_READY_TARGET_OUT_PATH="$(nix eval --accept-flake-config --raw "$HCI_AGENT_READY_TARGET_ATTR.outPath")"; then
    log "ERROR: could not evaluate $HCI_AGENT_READY_TARGET_ATTR.outPath."
    return 1
  fi
}

try_realise_ready_target() {
  if nix path-info "$HCI_AGENT_READY_TARGET_OUT_PATH" >/dev/null 2>&1; then
    return 0
  fi

  log "HCI ready target $HCI_AGENT_READY_TARGET_NAME is not local; attempting substitute-only realisation..."
  if nix build \
    --accept-flake-config \
    --option max-jobs 0 \
    --no-link \
    "$HCI_AGENT_READY_TARGET_ATTR"; then
    return 0
  fi

  return 1
}

emit_ready_target_ready() {
  log "HCI_READY_TARGET_AVAILABLE system=$HCI_AGENT_SYSTEM name=$HCI_AGENT_READY_TARGET_NAME attr=$HCI_AGENT_READY_TARGET_ATTR outPath=$HCI_AGENT_READY_TARGET_OUT_PATH"
}

monitor_ready_targets() {
  local job_id="$1"
  local deadline="$2"
  local job_json status
  local targets_available=0

  log "Monitoring Hercules CI job $job_id for $HCI_AGENT_SYSTEM."
  log "Note: any capable HCI agent may satisfy work; this runner proves additive capacity and ready target availability."

  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$targets_available" -eq 0 ] && try_realise_ready_target; then
      targets_available=1
      emit_ready_target_ready
      log "Configured HCI ready target is available."
    fi

    if ! job_json="$(hci_api_get "/api/v1/jobs/$job_id")"; then
      log "WARNING: failed to fetch Hercules CI job $job_id; retrying."
      sleep "$HCI_AGENT_POLL_SECONDS"
      continue
    fi

    if ! status="$(classify_hci_job "$job_json")"; then
      log "ERROR: could not classify Hercules CI job $job_id."
      emit_job_status "$job_json"
      return 1
    fi

    case "$status" in
      failure)
        log "ERROR: Hercules CI job $job_id failed."
        emit_job_status "$job_json"
        return 1
        ;;
      success)
        if [ "$targets_available" -eq 1 ] || try_realise_ready_target; then
          if [ "$targets_available" -eq 0 ]; then
            targets_available=1
            emit_ready_target_ready
          fi
          log "Hercules CI job $job_id completed successfully for $HCI_AGENT_SYSTEM."
          return 0
        fi

        log "ERROR: Hercules CI job $job_id completed, but ready targets are still unavailable via substitute-only realisation."
        emit_job_status "$job_json"
        return 1
        ;;
      unknown)
        log "ERROR: Hercules CI job $job_id is done, but status fields are absent or not success-like."
        emit_job_status "$job_json"
        return 1
        ;;
      running)
        if [ "$targets_available" -eq 1 ]; then
          log "Hercules CI job $job_id is still active; ready targets are available."
        else
          log "Hercules CI job $job_id is still active; ready targets are not available yet."
        fi
        ;;
      *)
        log "ERROR: unexpected Hercules CI job status classification: $status"
        return 1
        ;;
    esac

    sleep "$HCI_AGENT_POLL_SECONDS"
  done

  if [ "$targets_available" -eq 1 ]; then
    log "ERROR: timed out waiting for Hercules CI job $job_id to finish."
  else
    log "ERROR: timed out waiting for HCI ready targets for $HCI_AGENT_SYSTEM."
  fi
  return 1
}

main() {
  local deadline job_discovery_deadline job_id wait_status

  require_env HCI_AGENT_SYSTEM
  require_env GITHUB_SHA
  require_env HERCULES_CI_CREDENTIALS_JSON
  require_positive_integer HCI_AGENT_JOB_DISCOVERY_SECONDS
  require_positive_integer HCI_AGENT_POLL_SECONDS
  require_positive_integer HCI_AGENT_STARTUP_SECONDS
  require_positive_integer HCI_AGENT_TIMEOUT_SECONDS

  parse_hci_project
  validate_ready_target

  HCI_API_TOKEN="$(extract_hci_token "$HERCULES_CI_CREDENTIALS_JSON")"
  deadline=$((SECONDS + HCI_AGENT_TIMEOUT_SECONDS))
  job_discovery_deadline=$((SECONDS + HCI_AGENT_JOB_DISCOVERY_SECONDS))

  set_agent_hostname
  write_agent_files
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  start_final_gate_job_name_resolver
  start_agent
  prepare_ready_target

  if try_realise_ready_target; then
    emit_ready_target_ready
    log "Configured HCI ready target is available before HCI job discovery."
  fi

  wait_status=0
  job_id="$(wait_for_job_id "$GITHUB_SHA" "$deadline" "$job_discovery_deadline")" || wait_status="$?"
  case "$wait_status" in
    0)
      emit_job_found_output true
      ;;
    2)
      emit_job_found_output false
      notice "No Hercules CI job appeared for $HCI_PROJECT revision $GITHUB_SHA within ${HCI_AGENT_JOB_DISCOVERY_SECONDS}s; assuming HCI is paused."
      return 0
      ;;
    *)
      emit_job_found_output false
      return "$wait_status"
      ;;
  esac

  monitor_ready_targets "$job_id" "$deadline"
}

if [ "${HCI_AGENT_SUPERVISOR_LIB_ONLY:-}" != "1" ]; then
  bootstrap_hci_agent_tools "$@"
  main "$@"
fi
