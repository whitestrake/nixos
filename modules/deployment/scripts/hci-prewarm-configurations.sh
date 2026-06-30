#!/usr/bin/env bash
set -euo pipefail

repo_url="${HCI_PREWARM_REPO_URL:-https://github.com/whitestrake/nixos.git}"
branch="${HCI_PREWARM_BRANCH:-master}"
checkout_dir="${HCI_PREWARM_CHECKOUT_DIR:-/var/lib/hci-prewarm/nixos}"
gcroot_dir="${HCI_PREWARM_GCROOT_DIR:-/nix/var/nix/gcroots/hci-prewarm}"
keep_revisions="${HCI_PREWARM_KEEP_REVISIONS:-3}"
sleep_seconds="${HCI_PREWARM_SLEEP_SECONDS:-120}"
lock_file="${HCI_PREWARM_LOCK_FILE:-/run/hci-prewarm-configurations.lock}"
dry_run_only="${HCI_PREWARM_DRY_RUN_ONLY:-false}"
agent_service="${HCI_PREWARM_AGENT_SERVICE:-}"
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

if ! [[ "$keep_revisions" =~ ^[1-9][0-9]*$ ]]; then
  fail "HCI_PREWARM_KEEP_REVISIONS must be a positive integer, got: $keep_revisions"
fi

if ! [[ "$sleep_seconds" =~ ^[0-9]+$ ]]; then
  fail "HCI_PREWARM_SLEEP_SECONDS must be a non-negative integer, got: $sleep_seconds"
fi

mkdir -p "$(dirname "$lock_file")"
exec 9> "$lock_file"
if ! flock -n 9; then
  log "event=lock status=busy lock_file=$lock_file message=another-prewarm-run-is-active"
  exit 0
fi
log "event=lock status=acquired lock_file=$lock_file"

log "event=start repo_url=$repo_url branch=$branch checkout_dir=$checkout_dir gcroot_dir=$gcroot_dir keep_revisions=$keep_revisions sleep_seconds=$sleep_seconds dry_run_only=$dry_run_only agent_service=${agent_service:-none}"

update_checkout() {
  local before_rev="none"
  local after_rev

  if [ -d "$checkout_dir/.git" ]; then
    before_rev="$(git -C "$checkout_dir" rev-parse --verify HEAD 2>/dev/null || printf 'unknown')"
    log "event=checkout action=fetch status=start checkout_dir=$checkout_dir before_rev=$before_rev branch=$branch"
    git -C "$checkout_dir" fetch --prune origin "$branch"
    git -C "$checkout_dir" reset --hard "origin/$branch"
  else
    log "event=checkout action=clone status=start repo_url=$repo_url branch=$branch checkout_dir=$checkout_dir"
    mkdir -p "$(dirname "$checkout_dir")"
    git clone --branch "$branch" --single-branch "$repo_url" "$checkout_dir"
  fi

  after_rev="$(git -C "$checkout_dir" rev-parse --verify HEAD)"
  log "event=checkout status=complete checkout_dir=$checkout_dir before_rev=$before_rev after_rev=$after_rev"
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

  printf '%s\n' "$out_path" > "$all_drv_outputs"
  log "event=config status=fetch_final kind=$kind name=$name path=$out_path"
  if ! fetch_store_paths "final-output" "$all_drv_outputs"; then
    log "event=config status=miss_final kind=$kind name=$name attr=$attr out_path=$out_path fetched=$FETCH_FETCHED skipped=$FETCH_SKIPPED missed=$FETCH_MISSED duration_seconds=$((SECONDS - started))"
    return 20
  fi
  log "event=config status=fetch_final_summary kind=$kind name=$name path=$out_path fetched=$FETCH_FETCHED skipped=$FETCH_SKIPPED missed=$FETCH_MISSED"

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

  ln -sfn "$out_path" "$root"

  target="$(root_target "$root")"
  log "event=config status=warmed kind=$kind name=$name attr=$attr root=$root target=$target build_outputs_root=$build_outputs_root build_output_paths=$build_output_count duration_seconds=$((SECONDS - started))"

  return 0
}

prune_old_roots() {
  local current_rev_dir="$1"
  local promoted_rev_dir
  local protected_count
  local keep_previous
  local index
  local -a previous_rev_dirs
  local -a stale_dirs

  promoted_rev_dir="$(readlink -f "$gcroot_dir/current" 2> /dev/null || true)"
  protected_count=1
  if [ -n "$promoted_rev_dir" ] && [ "$promoted_rev_dir" != "$current_rev_dir" ]; then
    protected_count=2
  fi

  keep_previous=$((keep_revisions - protected_count))
  if [ "$keep_previous" -lt 0 ]; then
    keep_previous=0
  fi

  mapfile -t previous_rev_dirs < <(
    find "$gcroot_dir" \
      -maxdepth 1 \
      -mindepth 1 \
      -type d \
      -name 'rev-*' \
      -printf '%T@ %p\n' |
      sort -rn |
      cut -d' ' -f2- |
      while IFS= read -r rev_dir; do
        if [ "$rev_dir" = "$current_rev_dir" ] || { [ -n "$promoted_rev_dir" ] && [ "$rev_dir" = "$promoted_rev_dir" ]; }; then
          continue
        fi
        printf '%s\n' "$rev_dir"
      done
  )

  if [ "${#previous_rev_dirs[@]}" -le "$keep_previous" ]; then
    log "event=prune status=skip gcroot_dir=$gcroot_dir active_rev_dir=$current_rev_dir promoted_rev_dir=${promoted_rev_dir:-none} previous_count=${#previous_rev_dirs[@]} keep_previous=$keep_previous"
    return 0
  fi

  stale_dirs=()
  for index in "${!previous_rev_dirs[@]}"; do
    if [ "$index" -ge "$keep_previous" ]; then
      stale_dirs+=("${previous_rev_dirs[$index]}")
    fi
  done

  for stale_dir in "${stale_dirs[@]}"; do
    case "$stale_dir" in
      "$gcroot_dir"/rev-*)
        log "event=prune status=remove stale_dir=$stale_dir"
        rm -rf "$stale_dir"
        ;;
      *)
        fail "refusing to prune unexpected path: $stale_dir"
        ;;
    esac
  done
}

update_checkout

rev="$(git -C "$checkout_dir" rev-parse --verify HEAD)"
rev_dir="$gcroot_dir/rev-$rev"
mkdir -p "$rev_dir"

log "event=revision status=active branch=$branch rev=$rev rev_dir=$rev_dir"

warmed=0
skipped=0
missed=0
total=0
stopped_for_workers=0

for kind in nixosConfigurations darwinConfigurations; do
  names_file="$(mktemp)"
  tmp_files+=("$names_file")
  log "event=enumerate status=start kind=$kind"
  if ! enumerate_names "$kind" > "$names_file"; then
    rm -f "$names_file"
    fail "failed to enumerate $kind"
  fi
  kind_count="$(grep -c . "$names_file" || true)"
  log "event=enumerate status=complete kind=$kind count=$kind_count"

  while IFS= read -r name; do
    if [ -z "$name" ]; then
      continue
    fi

    set +e
    ensure_agent_idle
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      log "event=idle status=stop kind=$kind name=$name reason=worker-check-failed worker_check_status=$status"
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
      log "event=pace status=sleep kind=$kind name=$name sleep_seconds=$sleep_seconds"
      sleep "$sleep_seconds"
    fi
  done < "$names_file"
  rm -f "$names_file"
done

log "event=summary status=complete warmed=$warmed skipped=$skipped missed=$missed total=$total duration_seconds=$((SECONDS - run_started))"

if [ "$stopped_for_workers" = "1" ]; then
  log "event=promotion status=skipped reason=agent-became-busy rev=$rev rev_dir=$rev_dir"
  prune_old_roots "$rev_dir"
  exit 0
fi

if [ "$missed" -gt 0 ]; then
  log "event=promotion status=skipped reason=misses rev=$rev rev_dir=$rev_dir missed=$missed"
  prune_old_roots "$rev_dir"
  exit 1
fi

log "event=promotion status=start rev=$rev rev_dir=$rev_dir current=$gcroot_dir/current"
ln -sfn "$rev_dir" "$gcroot_dir/current"
log "event=promotion status=complete rev=$rev current=$gcroot_dir/current"
prune_old_roots "$rev_dir"
log "event=finish status=success rev=$rev duration_seconds=$((SECONDS - run_started))"
