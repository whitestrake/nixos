#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/hci-deployables-ci-gate.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"
cat > "$tmp_dir/bin/curl" <<'SH'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  *'&page=1')
    jq -cn '[range(0; 100) | {context: ("ctx-" + tostring), state: "success", blob: ("x" * 50000)}]'
    ;;
  *'&page=2')
    jq -cn '[{context: "last", state: "success"}]'
    ;;
  *)
    exit 1
    ;;
esac
SH
chmod +x "$tmp_dir/bin/curl"
export PATH="$tmp_dir/bin:$PATH"
export CI_GATE_GITHUB_TOKEN=dummy
export GITHUB_API_URL=https://example.invalid
export GITHUB_REPOSITORY=whitestrake/nixos
export HCI_CI_GATE_GITHUB_STATUS_PAGES=2
export HCI_CI_GATE_TIMEOUT_SECONDS=1
export HCI_CI_GATE_POLL_INTERVAL_SECONDS=1

# shellcheck source=/dev/null
source "$script"

actual="$(ci_gate_poll_github '["last"]' deadbeef | jq -c '{state: .state, contexts: (.contexts | length), pending: (.pendingContexts | length)}')"
expected='{"state":"green","contexts":1,"pending":0}'

if [ "$actual" != "$expected" ]; then
  printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
  exit 1
fi
