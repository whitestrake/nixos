#!/usr/bin/env bash
# Shared ordinary CI and exact-image validation workload.
set -euo pipefail
trap 'echo "CI_NFB_COMPLETE status=$? durationSeconds=$SECONDS"' EXIT
projection="$1"
system="$2"
result_dir="${CI_DARWIN_ATTEMPT_DIR:-$RUNNER_TEMP/ci-results}"
mkdir -p "$result_dir"
root="/nix/var/nix/gcroots/github-ci/$system/nix-fast-build"
nfb=()
if [ -d "$root" ]; then
  cached="$(cd -P "$root" && pwd)/bin/nix-fast-build"
  if [ -x "$cached" ] && nix path-info "${cached%/bin/nix-fast-build}" >/dev/null && "$cached" --help >/dev/null; then
    nfb=("$cached")
    echo "NIX_FAST_BUILD_SOURCE source=cache-root path=$cached"
  fi
fi
if [ "${#nfb[@]}" -eq 0 ]; then
  path="$(nix build --no-link --print-out-paths --option builders '' --option max-jobs auto ".#packages.$system.nix-fast-build")"
  nfb=("$path/bin/nix-fast-build")
  echo "NIX_FAST_BUILD_SOURCE source=nix-build path=$path"
  if [ "$system" = aarch64-darwin ]; then
    evaluator="$(nix build --inputs-from . --no-link --print-out-paths nixpkgs-unstable#nix-eval-jobs)"
    perl -e 'alarm shift; exec @ARGV' 60 "$evaluator/bin/nix-eval-jobs" --workers 1 --expr '{}' >/dev/null
    echo NIX_STORE_MIGRATION_PREFLIGHT_COMPLETE
  fi
fi
wrapper=("${HOST_PYTHON:-python3}" .github/scripts/nix_fast_build.py)
if [ "${CI_PUBLISH_CHECKS:-false}" = true ]; then wrapper+=(--publish-checks); fi
options=(--systems "$system" --eval-workers 1 --option builders '' --option max-jobs auto)
case "$projection" in
  linux-hosts) options=(--systems 'x86_64-linux aarch64-linux' --eval-workers 3 --store ssh-ng://eu.nixbuild.net --option max-jobs 2) ;;
  darwin)
    if [ "${CI_PUBLISH_CHECKS:-false}" = true ]; then options+=(--cachix-cache whitestrake); fi
    ;;
esac
"${wrapper[@]}" -- "${nfb[@]}" --flake ".#ci.$projection" "${options[@]}" \
  --retries 2 --result-file "$result_dir/results.json" -j 50
[ "$projection" != linux-checks ] || exit 0
jq -ce -f .github/scripts/nix-fast-build-records.jq "$result_dir/results.json" > "$result_dir/records.json"
if [ -n "${CI_EXPECTED_RECORDS:-}" ]; then
  expected="$(jq -cS 'map({attr,storePath}) | sort_by(.attr)' "$CI_EXPECTED_RECORDS")"
  actual="$(jq -cS 'map({attr,storePath}) | sort_by(.attr)' "$result_dir/records.json")"
  [ "$expected" = "$actual" ] || { echo '::error ::Workload differs from accepted proof'; exit 1; }
fi
