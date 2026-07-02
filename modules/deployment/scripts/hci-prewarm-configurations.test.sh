#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/hci-prewarm-configurations.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

lib="$tmp_dir/lib.sh"
awk '
  $0 == "update_checkout" { exit }
  { print }
' "$script" > "$lib"
export HCI_PREWARM_LOCK_FILE="$tmp_dir/prewarm.lock"
export HCI_PREWARM_CHECKOUT_DIR="$tmp_dir/checkout"
export HCI_PREWARM_GCROOT_DIR="$tmp_dir/gcroots"
export HCI_PREWARM_SLEEP_SECONDS=0
mkdir -p "$tmp_dir/bin"
printf '#!/bin/sh\nexit 0\n' > "$tmp_dir/bin/flock"
chmod +x "$tmp_dir/bin/flock"
export PATH="$tmp_dir/bin:$PATH"
# shellcheck source=/dev/null
source "$lib"

jobs="$tmp_dir/jobs.json"
cat > "$jobs" <<'JSON'
[
  {
    "project": {"siteSlug": "github", "ownerSlug": "whitestrake", "slug": "nixos"},
    "jobs": [
      {"index": 120, "jobName": "20-nixosConfiguration-jaeger", "jobPhase": "Running", "jobStatus": "Success", "evaluationStatus": "Success", "derivationStatus": "Success", "effectsStatus": "Success", "isCancelled": false, "source": {"ref": "refs/heads/master", "revision": "master-pending"}},
      {"index": 119, "jobName": "10-darwinConfiguration-andred", "jobPhase": "Done", "jobStatus": "Success", "evaluationStatus": "Success", "derivationStatus": "Success", "effectsStatus": "Success", "isCancelled": false, "source": {"ref": "refs/heads/master", "revision": "master-ready"}},
      {"index": 118, "jobName": "20-nixosConfiguration-jaeger", "jobPhase": "Done", "jobStatus": "Success", "evaluationStatus": "Success", "derivationStatus": "Success", "effectsStatus": "Success", "isCancelled": false, "source": {"ref": "refs/heads/master", "revision": "master-ready"}},
      {"index": 117, "jobName": "20-nixosConfiguration-jaeger", "jobPhase": "Done", "jobStatus": "Success", "evaluationStatus": "Success", "derivationStatus": "Failure", "effectsStatus": "Success", "isCancelled": false, "source": {"ref": "refs/heads/topic-bad", "revision": "topic-bad"}},
      {"index": 116, "jobName": "10-darwinConfiguration-andred", "jobPhase": "Done", "jobStatus": "Success", "evaluationStatus": "Success", "derivationStatus": "Success", "effectsStatus": "Success", "isCancelled": false, "source": {"ref": "refs/heads/topic-ready", "revision": "topic-ready"}},
      {"index": 115, "jobName": "20-nixosConfiguration-jaeger", "jobPhase": "Done", "jobStatus": "Success", "evaluationStatus": "Success", "derivationStatus": "Success", "effectsStatus": "Success", "isCancelled": false, "source": {"ref": "refs/heads/topic-ready", "revision": "topic-ready"}}
    ]
  },
  {
    "project": {"siteSlug": "github", "ownerSlug": "someone-else", "slug": "nixos"},
    "jobs": [
      {"index": 999, "jobName": "20-nixosConfiguration-jaeger", "jobPhase": "Done", "jobStatus": "Success", "evaluationStatus": "Success", "derivationStatus": "Success", "effectsStatus": "Success", "isCancelled": false, "source": {"ref": "refs/heads/master", "revision": "wrong-project"}}
    ]
  }
]
JSON

expected=$'master\trefs/heads/master\tmaster-ready\t119\nnon-master\trefs/heads/topic-ready\ttopic-ready\t116'
actual="$(select_hci_prewarm_candidates "$jobs" "github/whitestrake/nixos" "refs/heads/master")"

if [ "$actual" != "$expected" ]; then
  printf 'expected:\n%s\n\nactual:\n%s\n' "$expected" "$actual" >&2
  exit 1
fi
