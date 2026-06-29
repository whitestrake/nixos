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

  log "Removing stale prewarm root: $root"
  rm -f -- "$root"
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
  local dry_run_output
  local started="$SECONDS"
  local target
  local common_options=(
    --accept-flake-config
    --no-write-lock-file
    --option max-jobs 0
    --option builders ""
    --option fallback false
    --option max-substitution-jobs 1
    --option http-connections 1
  )

  quoted_name="$(quote_attr_segment "$name")"
  attr="path:$checkout_dir#${kind}.${quoted_name}.config.system.build.toplevel"
  root="$rev_dir/$(root_segment "${kind}-${name}")"

  if [ -e "$root" ] || [ -L "$root" ]; then
    if root_is_valid "$root"; then
      target="$(root_target "$root")"
      log "event=config status=skip_valid_root kind=$kind name=$name attr=$attr root=$root target=$target duration_seconds=$((SECONDS - started))"
      return 10
    fi
    remove_stale_root "$root" "$rev_dir"
  fi

  log "event=config status=checking kind=$kind name=$name attr=$attr root=$root"
  dry_run_output="$(mktemp)"
  tmp_files+=("$dry_run_output")
  if ! nix build "${common_options[@]}" --dry-run "$attr" > "$dry_run_output" 2>&1; then
    cat "$dry_run_output"
    rm -f "$dry_run_output"
    log "event=config status=miss_dry_run kind=$kind name=$name attr=$attr root=$root duration_seconds=$((SECONDS - started))"
    return 20
  fi
  cat "$dry_run_output"
  if grep -E -q 'will be built:' "$dry_run_output"; then
    rm -f "$dry_run_output"
    log "event=config status=miss_requires_build kind=$kind name=$name attr=$attr root=$root duration_seconds=$((SECONDS - started))"
    return 20
  fi
  rm -f "$dry_run_output"

  if [ "$dry_run_only" = "1" ] || [ "$dry_run_only" = "true" ]; then
    log "event=config status=dry_run_only kind=$kind name=$name attr=$attr root=$root duration_seconds=$((SECONDS - started))"
    return 0
  fi

  log "event=config status=warming kind=$kind name=$name attr=$attr root=$root"
  if ! nix build "${common_options[@]}" --out-link "$root" "$attr"; then
    log "event=config status=miss_build_failed kind=$kind name=$name attr=$attr root=$root duration_seconds=$((SECONDS - started))"
    return 20
  fi

  target="$(root_target "$root")"
  log "event=config status=warmed kind=$kind name=$name attr=$attr root=$root target=$target duration_seconds=$((SECONDS - started))"

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
