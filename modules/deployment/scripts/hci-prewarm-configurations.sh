#!/usr/bin/env bash
set -euo pipefail

repo_url="${HCI_PREWARM_REPO_URL:-https://github.com/whitestrake/nixos.git}"
branch="${HCI_PREWARM_BRANCH:-master}"
checkout_dir="${HCI_PREWARM_CHECKOUT_DIR:-/var/lib/hci-prewarm/nixos}"
gcroot_dir="${HCI_PREWARM_GCROOT_DIR:-/nix/var/nix/gcroots/hci-prewarm}"
sleep_seconds="${HCI_PREWARM_SLEEP_SECONDS:-120}"
lock_file="${HCI_PREWARM_LOCK_FILE:-/run/hci-prewarm-configurations.lock}"
dry_run_only="${HCI_PREWARM_DRY_RUN_ONLY:-false}"
agent_service="${HCI_PREWARM_AGENT_SERVICE:-}"
hci_project="${HCI_PREWARM_HCI_PROJECT:-${HCI_PROJECT:-github/whitestrake/nixos}}"
hci_api_base_url="${HCI_PREWARM_HCI_API_BASE_URL:-${HERCULES_CI_API_BASE_URL:-https://hercules-ci.com}}"
hci_api_url="${HCI_PREWARM_HCI_API_URL:-${HCI_API_URL:-${hci_api_base_url%/}/api/v1}}"
hci_jobs_file="${HCI_PREWARM_HCI_JOBS_FILE:-}"
hci_connect_timeout="${HCI_PREWARM_HCI_CONNECT_TIMEOUT_SECONDS:-10}"
hci_request_timeout="${HCI_PREWARM_HCI_REQUEST_TIMEOUT_SECONDS:-60}"
run_started="$SECONDS"
tmp_files=()
nix_common_options=(
  --accept-flake-config
  --no-write-lock-file
  --option max-jobs 0
  --option builders ""
  --option fallback false
  --option max-substitution-jobs 1
  --option http-connections 1
)

log() {
  printf '%s\n' "$*"
}

cleanup_tmp_files() {
  if [ "${#tmp_files[@]}" -gt 0 ]; then
    rm -f -- "${tmp_files[@]}"
  fi
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

trap cleanup_tmp_files EXIT

if ! [[ "$sleep_seconds" =~ ^[0-9]+$ ]]; then
  fail "HCI_PREWARM_SLEEP_SECONDS must be a non-negative integer, got: $sleep_seconds"
fi

if ! [[ "$hci_connect_timeout" =~ ^[1-9][0-9]*$ ]]; then
  fail "HCI_PREWARM_HCI_CONNECT_TIMEOUT_SECONDS must be a positive integer, got: $hci_connect_timeout"
fi

if ! [[ "$hci_request_timeout" =~ ^[1-9][0-9]*$ ]]; then
  fail "HCI_PREWARM_HCI_REQUEST_TIMEOUT_SECONDS must be a positive integer, got: $hci_request_timeout"
fi

mkdir -p "$(dirname "$lock_file")"
exec 9> "$lock_file"
if ! flock -n 9; then
  log "event=lock status=busy lock_file=$lock_file message=another-prewarm-run-is-active"
  exit 0
fi
log "event=lock status=acquired lock_file=$lock_file"

log "event=start repo_url=$repo_url branch=$branch checkout_dir=$checkout_dir gcroot_dir=$gcroot_dir sleep_seconds=$sleep_seconds dry_run_only=$dry_run_only agent_service=${agent_service:-none} hci_project=$hci_project"

update_checkout() {
  local ref="${1:-refs/heads/$branch}"
  local target_rev="${2:-}"
  local before_rev="none"
  local after_rev

  if [ -d "$checkout_dir/.git" ]; then
    before_rev="$(git -C "$checkout_dir" rev-parse --verify HEAD 2>/dev/null || printf 'unknown')"
    log "event=checkout action=fetch status=start checkout_dir=$checkout_dir before_rev=$before_rev ref=$ref target_rev=${target_rev:-FETCH_HEAD}"
  else
    log "event=checkout action=clone status=start repo_url=$repo_url checkout_dir=$checkout_dir ref=$ref target_rev=${target_rev:-FETCH_HEAD}"
    mkdir -p "$(dirname "$checkout_dir")" || return 1
    git clone --no-checkout "$repo_url" "$checkout_dir" || return 1
  fi

  git -C "$checkout_dir" fetch --prune origin "$ref" || return 1
  if [ -n "$target_rev" ]; then
    if ! git -C "$checkout_dir" cat-file -e "$target_rev^{commit}" 2> /dev/null; then
      log "event=checkout action=fetch_revision status=start checkout_dir=$checkout_dir target_rev=$target_rev"
      git -C "$checkout_dir" fetch origin "$target_rev" || true
    fi
    git -C "$checkout_dir" reset --hard "$target_rev" || return 1
  else
    git -C "$checkout_dir" reset --hard FETCH_HEAD || return 1
  fi

  after_rev="$(git -C "$checkout_dir" rev-parse --verify HEAD)" || return 1
  log "event=checkout status=complete checkout_dir=$checkout_dir before_rev=$before_rev after_rev=$after_rev ref=$ref"
}

enumerate_names() {
  local kind="$1"

  nix eval \
    --accept-flake-config \
    --no-write-lock-file \
    --json \
    "path:$checkout_dir#$kind" \
    --apply builtins.attrNames \
    | jq -r '.[]' \
    | sort
}

quote_attr_segment() {
  jq -Rnr --arg value "$1" '$value | @json' | sed 's/\${/\\${/g'
}

root_segment() {
  jq -nr --arg value "$1" '$value | @uri'
}

root_is_valid() {
  local root="$1"
  local target

  if [ ! -L "$root" ]; then
    return 1
  fi

  target="$(readlink "$root")" || return 1
  case "$target" in
    /nix/store/*) ;;
    *) return 1 ;;
  esac

  nix path-info "$target" > /dev/null 2>&1
}

root_target() {
  local root="$1"

  if [ -L "$root" ]; then
    readlink "$root" || printf 'unknown'
  else
    printf 'none'
  fi
}

remove_stale_root() {
  local root="$1"
  local rev_dir="$2"

  case "$root" in
    "$rev_dir"/*) ;;
    *) fail "refusing to remove unexpected root path: $root" ;;
  esac

  if [ -d "$root" ] && [ ! -L "$root" ]; then
    fail "refusing to replace directory root: $root"
  fi

  log "event=root status=remove_stale root=$root"
  rm -f -- "$root"
}

path_is_valid() {
  nix path-info "$1" > /dev/null 2>&1
}

log_nix_excerpt() {
  local phase="$1"
  local output_file="$2"
  local total_lines
  local line_number
  local stream
  local line
  local message

  if [ ! -s "$output_file" ]; then
    log "event=nix_output phase=$phase status=empty"
    return 0
  fi

  total_lines="$(wc -l < "$output_file" | tr -d ' ')"
  while IFS=$'\t' read -r line_number stream line; do
    message="$(printf '%s' "$line" | jq -Rr @json)"
    log "event=nix_output phase=$phase stream=$stream line_number=$line_number message=$message"
  done < <(
    awk -v total="$total_lines" '
      total <= 80 {
        print NR "\tall\t" $0
        next
      }
      NR <= 40 {
        print NR "\thead\t" $0
        next
      }
      NR > total - 40 {
        print NR "\ttail\t" $0
      }
    ' "$output_file"
  )
}

parse_dry_run_drvs() {
  local dry_run_output="$1"
  local drv_list_file="$2"

  awk '
    BEGIN { in_derivations = 0 }
    /^[[:space:]]*this derivation will be built:/ || /^[[:space:]]*these [0-9]+ derivations will be built:/ {
      in_derivations = 1
      next
    }
    /^[[:space:]]*this path will be fetched/ || /^[[:space:]]*these [0-9]+ paths will be fetched/ {
      in_derivations = 0
    }
    in_derivations && $1 ~ /^\/nix\/store\/.*\.drv$/ {
      print $1
    }
  ' "$dry_run_output" | sort -u > "$drv_list_file"
}

dry_run_build_count() {
  awk '
    /^[[:space:]]*this derivation will be built:/ {
      print 1
      found = 1
      exit
    }
    /^[[:space:]]*these [0-9]+ derivations will be built:/ {
      print $2 + 0
      found = 1
      exit
    }
    END {
      if (!found) {
        print 0
      }
    }
  ' "$1"
}

dry_run_fetch_count() {
  awk '
    /^[[:space:]]*this path will be fetched/ {
      print 1
      found = 1
      exit
    }
    /^[[:space:]]*these [0-9]+ paths will be fetched/ {
      print $2 + 0
      found = 1
      exit
    }
    END {
      if (!found) {
        print 0
      }
    }
  ' "$1"
}

resolve_drv_outputs() {
  local drv_list_file="$1"
  local output_list_file="$2"
  local tmp_output_list
  local drv

  tmp_output_list="$(mktemp)"
  tmp_files+=("$tmp_output_list")
  : > "$tmp_output_list"

  while IFS= read -r drv; do
    if [ -z "$drv" ]; then
      continue
    fi
    if ! nix-store -q --outputs "$drv" >> "$tmp_output_list"; then
      log "event=drv_outputs status=failed drv=$drv"
      return 1
    fi
  done < "$drv_list_file"

  sort -u "$tmp_output_list" > "$output_list_file"
}

root_store_paths() {
  local root_dir="$1"
  local paths_file="$2"
  local path
  local root
  local unexpected

  case "$root_dir" in
    "$gcroot_dir"/rev-*/*-build-outputs) ;;
    *) fail "refusing to root build outputs outside revision root: $root_dir" ;;
  esac

  if [ -L "$root_dir" ] || { [ -e "$root_dir" ] && [ ! -d "$root_dir" ]; }; then
    fail "refusing to replace non-directory build-output root: $root_dir"
  fi

  mkdir -p "$root_dir"
  unexpected="$(
    find "$root_dir" \
      -mindepth 1 \
      -maxdepth 1 \
      ! -type l \
      -print \
      -quit
  )"
  if [ -n "$unexpected" ]; then
    fail "refusing to replace non-symlink build-output root: $unexpected"
  fi

  find "$root_dir" -mindepth 1 -maxdepth 1 -type l -delete
  while IFS= read -r path; do
    if [ -z "$path" ]; then
      continue
    fi
    root="$root_dir/$(root_segment "${path##*/}")"
    ln -sfn "$path" "$root"
  done < "$paths_file"
}

fetch_store_paths() {
  local phase="$1"
  local paths_file="$2"
  local path
  local output_file

  FETCH_FETCHED=0
  FETCH_SKIPPED=0
  FETCH_MISSED=0

  while IFS= read -r path; do
    if [ -z "$path" ]; then
      continue
    fi

    if path_is_valid "$path"; then
      FETCH_SKIPPED=$((FETCH_SKIPPED + 1))
      continue
    fi

    output_file="$(mktemp)"
    tmp_files+=("$output_file")
    if nix build "${nix_common_options[@]}" --no-link "$path" > "$output_file" 2>&1 && path_is_valid "$path"; then
      FETCH_FETCHED=$((FETCH_FETCHED + 1))
      rm -f "$output_file"
      continue
    fi

    FETCH_MISSED=$((FETCH_MISSED + 1))
    log "event=fetch status=miss phase=$phase path=$path"
    log_nix_excerpt "$phase" "$output_file"
    rm -f "$output_file"
  done < "$paths_file"

  [ "$FETCH_MISSED" -eq 0 ]
}

agent_has_workers() {
  local service="$1"
  local control_group
  local cgroup_dir
  local proc_file
  local pid
  local cmdline
  local found_proc_file=0

  if ! command -v systemctl > /dev/null 2>&1; then
    return 2
  fi

  control_group="$(systemctl show -p ControlGroup --value "$service" 2> /dev/null || true)"
  if [ -z "$control_group" ]; then
    return 2
  fi

  cgroup_dir="/sys/fs/cgroup$control_group"
  if [ ! -d "$cgroup_dir" ]; then
    return 2
  fi

  while IFS= read -r -d '' proc_file; do
    found_proc_file=1
    while IFS= read -r pid; do
      if [ -z "$pid" ] || [ ! -r "/proc/$pid/cmdline" ]; then
        continue
      fi

      cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" || true)"
      case "$cmdline" in
        *hercules-ci-agent-worker*)
          log "event=idle status=busy service=$service pid=$pid cmdline=$cmdline"
          return 0
          ;;
      esac
    done < "$proc_file"
  done < <(find "$cgroup_dir" -name cgroup.procs -type f -readable -print0)

  if [ "$found_proc_file" = "0" ]; then
    return 2
  fi

  return 1
}

ensure_agent_idle() {
  local status

  if [ -z "$agent_service" ]; then
    return 0
  fi

  if agent_has_workers "$agent_service"; then
    return 30
  else
    status=$?
  fi

  if [ "$status" = "2" ]; then
    log "event=idle status=unknown service=$agent_service message=skipping-prewarm-to-avoid-competing-with-hci"
    return 31
  fi

  return 0
}

prewarm_attr() {
  local kind="$1"
  local name="$2"
  local rev_dir="$3"
  local quoted_name
  local attr
  local root
  local build_outputs_root
  local eval_output
  local dry_run_output
  local drv_list
  local all_drv_outputs
  local build_outputs
  local started="$SECONDS"
  local out_path
  local target
  local will_build_derivations
  local will_fetch_paths
  local build_output_count
  local build_fetch_fetched
  local build_fetch_skipped
  local build_fetch_missed

  quoted_name="$(quote_attr_segment "$name")"
  attr="path:$checkout_dir#${kind}.${quoted_name}.config.system.build.toplevel"
  root="$rev_dir/$(root_segment "${kind}-${name}")"
  build_outputs_root="$rev_dir/$(root_segment "${kind}-${name}-build-outputs")"

  if root_is_valid "$root"; then
    target="$(root_target "$root")"
    log "event=config status=skip_valid_root kind=$kind name=$name attr=$attr root=$root target=$target build_outputs_root=$build_outputs_root duration_seconds=$((SECONDS - started))"
    return 10
  fi

  if [ -e "$root" ] || [ -L "$root" ]; then
    remove_stale_root "$root" "$rev_dir"
  fi

  log "event=config status=checking kind=$kind name=$name attr=$attr root=$root build_outputs_root=$build_outputs_root"

  eval_output="$(mktemp)"
  tmp_files+=("$eval_output")
  if ! out_path="$(nix eval "${nix_common_options[@]}" --raw "$attr.outPath" 2> "$eval_output")"; then
    log "event=config status=miss_eval_out_path kind=$kind name=$name attr=$attr duration_seconds=$((SECONDS - started))"
    log_nix_excerpt "eval-out-path" "$eval_output"
    rm -f "$eval_output"
    return 20
  fi

  rm -f "$eval_output"

  dry_run_output="$(mktemp)"
  drv_list="$(mktemp)"
  all_drv_outputs="$(mktemp)"
  build_outputs="$(mktemp)"
  tmp_files+=("$dry_run_output")
  tmp_files+=("$drv_list")
  tmp_files+=("$all_drv_outputs")
  tmp_files+=("$build_outputs")
  if ! nix build "${nix_common_options[@]}" --dry-run "$attr" > "$dry_run_output" 2>&1; then
    log "event=config status=miss_dry_run kind=$kind name=$name attr=$attr out_path=$out_path duration_seconds=$((SECONDS - started))"
    log_nix_excerpt "dry-run" "$dry_run_output"
    return 20
  fi

  will_build_derivations="$(dry_run_build_count "$dry_run_output")"
  will_fetch_paths="$(dry_run_fetch_count "$dry_run_output")"
  parse_dry_run_drvs "$dry_run_output" "$drv_list"
  if ! resolve_drv_outputs "$drv_list" "$all_drv_outputs"; then
    log "event=config status=miss_drv_outputs kind=$kind name=$name attr=$attr out_path=$out_path duration_seconds=$((SECONDS - started))"
    return 20
  fi

  grep -F -x -v -- "$out_path" "$all_drv_outputs" > "$build_outputs" || true
  build_output_count="$(grep -c . "$build_outputs" || true)"
  rm -f "$dry_run_output"

  log "event=config status=dry_run_summary kind=$kind name=$name attr=$attr out_path=$out_path will_build_derivations=$will_build_derivations will_fetch_paths=$will_fetch_paths build_output_paths=$build_output_count"

  if [ "$dry_run_only" = "1" ] || [ "$dry_run_only" = "true" ]; then
    log "event=config status=dry_run_only kind=$kind name=$name attr=$attr root=$root build_outputs_root=$build_outputs_root out_path=$out_path duration_seconds=$((SECONDS - started))"
    return 0
  fi

  log "event=config status=fetch_build_outputs kind=$kind name=$name planned=$build_output_count root=$build_outputs_root"
  if ! fetch_store_paths "build-outputs" "$build_outputs"; then
    build_fetch_fetched="$FETCH_FETCHED"
    build_fetch_skipped="$FETCH_SKIPPED"
    build_fetch_missed="$FETCH_MISSED"
    log "event=config status=fetch_build_outputs_summary kind=$kind name=$name planned=$build_output_count fetched=$build_fetch_fetched skipped=$build_fetch_skipped missed=$build_fetch_missed"
    log "event=config status=miss_build_outputs kind=$kind name=$name attr=$attr out_path=$out_path duration_seconds=$((SECONDS - started))"
    return 20
  fi
  build_fetch_fetched="$FETCH_FETCHED"
  build_fetch_skipped="$FETCH_SKIPPED"
  build_fetch_missed="$FETCH_MISSED"
  log "event=config status=fetch_build_outputs_summary kind=$kind name=$name planned=$build_output_count fetched=$build_fetch_fetched skipped=$build_fetch_skipped missed=$build_fetch_missed"

  if [ "$build_output_count" -gt 0 ]; then
    root_store_paths "$build_outputs_root" "$build_outputs"
  fi

  printf '%s\n' "$out_path" > "$all_drv_outputs"
  log "event=config status=fetch_final kind=$kind name=$name path=$out_path"
  if ! fetch_store_paths "final-output" "$all_drv_outputs"; then
    log "event=config status=miss_final kind=$kind name=$name attr=$attr out_path=$out_path fetched=$FETCH_FETCHED skipped=$FETCH_SKIPPED missed=$FETCH_MISSED duration_seconds=$((SECONDS - started))"
    return 20
  fi
  log "event=config status=fetch_final_summary kind=$kind name=$name path=$out_path fetched=$FETCH_FETCHED skipped=$FETCH_SKIPPED missed=$FETCH_MISSED"

  ln -sfn "$out_path" "$root"

  target="$(root_target "$root")"
  log "event=config status=warmed kind=$kind name=$name attr=$attr root=$root target=$target build_outputs_root=$build_outputs_root build_output_paths=$build_output_count duration_seconds=$((SECONDS - started))"

  return 0
}

hci_curl() {
  local path="$1"

  curl -fsS --connect-timeout "$hci_connect_timeout" --max-time "$hci_request_timeout" "${hci_api_url%/}$path"
}

parse_hci_project() {
  local project="$1"
  local site owner repo extra

  IFS=/ read -r site owner repo extra <<< "$project"
  [ -n "${site:-}" ] && [ -n "${owner:-}" ] && [ -n "${repo:-}" ] && [ -z "${extra:-}" ] || {
    printf 'ERROR: HCI project must have the form site/owner/repo, got: %s\n' "$project" >&2
    return 1
  }

  printf '%s\t%s\t%s\n' "$site" "$owner" "$repo"
}

fetch_hci_jobs_page() {
  local revision="$1"
  local offset="${2:-}"
  local site owner repo path

  if [ -n "$hci_jobs_file" ]; then
    [ -r "$hci_jobs_file" ] || {
      log "event=hci_lookup status=failed reason=jobs-file-unreadable path=$hci_jobs_file"
      return 1
    }
    cat "$hci_jobs_file"
    return
  fi

  parse_hci_project "$hci_project" >/dev/null || return 1
  IFS=$'\t' read -r site owner repo < <(parse_hci_project "$hci_project")
  path="/site/$site/account/$owner/project/$repo/jobs?rev=$revision&handler=OnPush"
  if [ -n "$offset" ]; then
    path="$path&offsetIndex=$offset"
  fi

  hci_curl "$path"
}

fetch_hci_jobs() {
  local revision="$1"
  local offset="" page next jobs_tmp

  if [ -n "$hci_jobs_file" ]; then
    page="$(fetch_hci_jobs_page "$revision")" || return 1
    if ! jq -e 'type == "object" and (.items | type == "array")' <<< "$page" >/dev/null; then
      log "event=hci_lookup status=failed reason=invalid-jobs-response"
      return 1
    fi
    jq -c '.items' <<< "$page"
    return
  fi

  jobs_tmp="$(mktemp)"
  tmp_files+=("$jobs_tmp")
  : > "$jobs_tmp"

  while true; do
    page="$(fetch_hci_jobs_page "$revision" "$offset")" || return 1
    if ! jq -e 'type == "object" and (.items | type == "array") and (.more | type == "boolean")' <<< "$page" >/dev/null; then
      log "event=hci_lookup status=failed reason=invalid-paged-jobs-response"
      return 1
    fi

    jq -c '.items[]?' <<< "$page" >> "$jobs_tmp"

    if [ "$(jq -r '.more' <<< "$page")" != "true" ]; then
      break
    fi

    next="$(jq -r '[.items[]?.index] | max // empty' <<< "$page")"
    if [ -z "$next" ]; then
      log "event=hci_lookup status=failed reason=paged-jobs-missing-offset rev=$revision"
      return 1
    fi
    if [ "$next" = "$offset" ]; then
      log "event=hci_lookup status=failed reason=paged-jobs-stalled rev=$revision offset=$offset"
      return 1
    fi
    offset="$next"
  done

  if ! jq -s -c . "$jobs_tmp"; then
    log "event=hci_lookup status=failed reason=invalid-aggregated-jobs"
    return 1
  fi
}

summarize_hci_jobs_for_revision() {
  local jobs_file="$1"
  local revision="$2"

  jq -r \
    --arg revision "$revision" \
    '
      def failed: (. // "" | tostring | ascii_downcase) | test("fail|error|exception|cancel|timed|abort|unsuccess");
      def success: (. // "" | tostring | ascii_downcase) | test("^(success|succeed|succeeded|successful|done|pass|passed|complete|completed)$");
      def done($job): (($job.jobPhase // "") | tostring | ascii_downcase) == "done";
      def green($job):
        (($job.isCancelled // false) | not)
        and ([$job.jobStatus, $job.evaluationStatus, $job.derivationStatus, $job.effectsStatus] | map(. // empty) | all(failed | not))
        and done($job)
        and ($job.jobStatus | success)
        and ([$job.evaluationStatus, $job.derivationStatus, $job.effectsStatus] | map(. // "Success") | all(success));

      [
        .[]?
        | select(.source.revision == $revision)
        | {
            jobName: (.jobName // "unknown"),
            index: ((.index // 0) | tonumber? // 0),
            startTime: (.startTime // ""),
            green: green(.)
          }
      ]
      | sort_by(.jobName, .index, .startTime)
      | group_by(.jobName)
      | map(last) as $jobs
      | if ($jobs | length) == 0 then
          ["missing", "0", ""]
        elif all($jobs[]; .green) then
          ["green", ($jobs | length | tostring), ""]
        else
          ["pending", ($jobs | length | tostring), ($jobs | map(select(.green | not).jobName) | join(","))]
        end
      | @tsv
    ' "$jobs_file"
}

current_root_has_revision() {
  local current_root="$1"
  local rev="$2"
  local target

  target="$(readlink -f "$current_root" 2> /dev/null || true)"
  [ "$target" = "$gcroot_dir/rev-$rev" ] && [ -d "$target" ]
}

promote_current_root() {
  local current_root="$1"
  local rev="$2"
  local rev_dir="$3"

  if [ -e "$current_root" ] && [ ! -L "$current_root" ]; then
    fail "refusing to replace non-symlink current root: $current_root"
  fi

  mkdir -p "$(dirname "$current_root")"
  log "event=promotion status=start rev=$rev rev_dir=$rev_dir current=$current_root"
  ln -sfn "$rev_dir" "$current_root"
  log "event=promotion status=complete rev=$rev current=$current_root"
}

prewarm_revision() {
  local slot="$1"
  local ref="$2"
  local rev="$3"
  local current_root="$4"
  local rev_dir="$gcroot_dir/rev-$rev"
  local warmed=0
  local skipped=0
  local missed=0
  local total=0
  local stopped_for_workers=0
  local kind names_file kind_count name status
  local checkout_rev

  if current_root_has_revision "$current_root" "$rev"; then
    log "event=revision status=skip_current slot=$slot ref=$ref rev=$rev current=$current_root rev_dir=$rev_dir"
    return 0
  fi

  checkout_rev="$(git -C "$checkout_dir" rev-parse --verify HEAD 2> /dev/null || true)"
  if [ "$checkout_rev" = "$rev" ]; then
    log "event=checkout status=skip_current checkout_dir=$checkout_dir rev=$rev"
  else
    update_checkout "$ref" "$rev"
  fi
  mkdir -p "$rev_dir"
  log "event=revision status=active slot=$slot ref=$ref rev=$rev rev_dir=$rev_dir"

  for kind in nixosConfigurations darwinConfigurations; do
    names_file="$(mktemp)"
    tmp_files+=("$names_file")
    log "event=enumerate status=start slot=$slot kind=$kind"
    if ! enumerate_names "$kind" > "$names_file"; then
      rm -f "$names_file"
      fail "failed to enumerate $kind"
    fi
    kind_count="$(grep -c . "$names_file" || true)"
    log "event=enumerate status=complete slot=$slot kind=$kind count=$kind_count"

    while IFS= read -r name; do
      if [ -z "$name" ]; then
        continue
      fi

      set +e
      ensure_agent_idle
      status=$?
      set -e
      if [ "$status" -ne 0 ]; then
        log "event=idle status=stop slot=$slot kind=$kind name=$name reason=worker-check-failed worker_check_status=$status"
        stopped_for_workers=1
        break 2
      fi

      total=$((total + 1))
      set +e
      prewarm_attr "$kind" "$name" "$rev_dir"
      status=$?
      set -e

      case "$status" in
        0)
          warmed=$((warmed + 1))
          ;;
        10)
          skipped=$((skipped + 1))
          ;;
        20)
          missed=$((missed + 1))
          ;;
        *)
          fail "unexpected prewarm status $status for $kind.$name"
          ;;
      esac

      if [ "$sleep_seconds" -gt 0 ]; then
        log "event=pace status=sleep slot=$slot kind=$kind name=$name sleep_seconds=$sleep_seconds"
        sleep "$sleep_seconds"
      fi
    done < "$names_file"
    rm -f "$names_file"
  done

  log "event=summary status=complete slot=$slot warmed=$warmed skipped=$skipped missed=$missed total=$total duration_seconds=$((SECONDS - run_started))"

  if [ "$stopped_for_workers" = "1" ]; then
    log "event=promotion status=skipped slot=$slot reason=agent-became-busy rev=$rev rev_dir=$rev_dir"
    return 30
  fi

  if [ "$missed" -gt 0 ]; then
    log "event=promotion status=skipped slot=$slot reason=misses rev=$rev rev_dir=$rev_dir missed=$missed"
    return 20
  fi

  promote_current_root "$current_root" "$rev" "$rev_dir"
}

prune_slot_roots() {
  local current rev_dir protected stale_dir
  local -a protected_dirs

  protected_dirs=()
  if [ -L "$gcroot_dir/non-master/current" ]; then
    log "event=prune status=remove_legacy_current current=$gcroot_dir/non-master/current"
    rm -f "$gcroot_dir/non-master/current"
  fi

  for current in "$gcroot_dir/current" "$gcroot_dir/master/current"; do
    rev_dir="$(readlink -f "$current" 2> /dev/null || true)"
    case "$rev_dir" in
      "$gcroot_dir"/rev-*)
        protected_dirs+=("$rev_dir")
        ;;
    esac
  done

  while IFS= read -r stale_dir; do
    [ -n "$stale_dir" ] || continue
    protected=0
    for rev_dir in "${protected_dirs[@]}"; do
      if [ "$stale_dir" = "$rev_dir" ]; then
        protected=1
        break
      fi
    done
    if [ "$protected" = "1" ]; then
      continue
    fi

    case "$stale_dir" in
      "$gcroot_dir"/rev-*)
        log "event=prune status=remove stale_dir=$stale_dir"
        rm -rf "$stale_dir"
        ;;
      *)
        fail "refusing to prune unexpected path: $stale_dir"
        ;;
    esac
  done < <(find "$gcroot_dir" -maxdepth 1 -mindepth 1 -type d -name 'rev-*' | sort)
}

jobs_file="$(mktemp)"
tmp_files+=("$jobs_file")

if ! update_checkout; then
  log "event=checkout status=failed message=preserving-existing-roots"
  exit 0
fi
rev="$(git -C "$checkout_dir" rev-parse --verify HEAD)"
log "event=hci_lookup status=start rev=$rev"

if ! fetch_hci_jobs "$rev" > "$jobs_file"; then
  log "event=hci_lookup status=failed message=preserving-existing-roots"
  exit 0
fi

hci_summary="$(summarize_hci_jobs_for_revision "$jobs_file" "$rev")" || fail "failed to summarize HCI jobs for $rev"
IFS=$'\t' read -r hci_state hci_job_count hci_not_green <<< "$hci_summary"
log "event=hci_lookup status=complete rev=$rev state=$hci_state jobs=$hci_job_count not_green=${hci_not_green:-none}"
if [ "$hci_state" != "green" ]; then
  log "event=finish status=success reason=hci-$hci_state rev=$rev duration_seconds=$((SECONDS - run_started))"
  exit 0
fi

set +e
prewarm_revision "master" "refs/heads/$branch" "$rev" "$gcroot_dir/master/current"
status=$?
set -e

case "$status" in
  0)
    ;;
  20)
    log "event=finish status=failed slot=master reason=misses rev=$rev duration_seconds=$((SECONDS - run_started))"
    prune_slot_roots
    exit 1
    ;;
  30)
    log "event=finish status=deferred slot=master reason=agent-became-busy rev=$rev duration_seconds=$((SECONDS - run_started))"
    prune_slot_roots
    exit 0
    ;;
  *)
    fail "unexpected prewarm revision status $status for slot master"
    ;;
esac

prune_slot_roots
log "event=finish status=success mode=hci-discovery duration_seconds=$((SECONDS - run_started))"
