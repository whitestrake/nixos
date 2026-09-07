#!/usr/bin/env bash
set -euo pipefail

failure="$RUNNER_TEMP/failure"
mkdir -p "$failure"
sed "s|@SUBJECT@|$GITHUB_WORKSPACE|" "$GITHUB_WORKSPACE/.github/native-harness/intentional-failure.flake.nix" > "$failure/flake.nix"
nix flake lock "path:$failure"

root=/nix/var/nix/gcroots/github-ci/aarch64-darwin/nix-fast-build
cached="$(cd -P "$root" && pwd)/bin/nix-fast-build"
[ -x "$cached" ]
nix path-info "${cached%/bin/nix-fast-build}" >/dev/null
"$cached" --help >/dev/null
printf '%s\n' "$cached" > "$RUNNER_TEMP/evidence/nfb-path.txt"

"$HOST_PYTHON" .github/scripts/nix_fast_build.py --publish-checks -- \
  "$cached" --flake "path:$failure#ci.failure" \
  --systems aarch64-darwin --eval-workers 1 --option builders '' \
  --option max-jobs auto --retries 0 \
  --result-file "$CI_DARWIN_ATTEMPT_DIR/results.json" -j 1
