#!/usr/bin/env bash
set -euo pipefail

deployables_json="${DEPLOYABLES_JSON:-}"
state_history_limit="${HCI_DEPLOYABLES_HISTORY_LIMIT:-10}"
state_name="deployables.json"

if [ -z "$deployables_json" ]; then
  echo "ERROR: DEPLOYABLES_JSON is empty." >&2
  exit 1
fi

if ! [[ "$state_history_limit" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HCI_DEPLOYABLES_HISTORY_LIMIT must be a positive integer." >&2
  exit 1
fi

required_filter='
  type == "object"
  and (.rev | type == "string" and length > 0)
  and (.shortRev | type == "string" and length > 0)
  and (.branch | type == "string" and length > 0)
  and (.ref | type == "string" and length > 0)
  and (.deployables | type == "array" and length > 0)
  and all(.deployables[]; type == "string" and length > 0)
'

if ! printf '%s\n' "$deployables_json" | jq -e "$required_filter" >/dev/null; then
  echo "ERROR: DEPLOYABLES_JSON is malformed." >&2
  printf '%s\n' "$deployables_json" | jq . >&2 || printf '%s\n' "$deployables_json" >&2
  exit 1
fi

rev="$(printf '%s\n' "$deployables_json" | jq -r '.rev')"
work_dir="$(mktemp -d)"
old_state="$work_dir/state-old.json"
new_state="$work_dir/state-new.json"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

getStateFile "$state_name" "$old_state"

if [ -e "$old_state" ] && ! jq -e 'type == "object"' "$old_state" >/dev/null; then
  echo "Existing state $state_name is malformed; replacing it." >&2
  rm -f "$old_state"
fi

if [ ! -e "$old_state" ]; then
  jq -n '{}' > "$old_state"
fi

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq \
  --argjson current "$deployables_json" \
  --arg rev "$rev" \
  --arg timestamp "$timestamp" \
  --argjson limit "$state_history_limit" \
  '
    def currentRecord:
      $current | del(.rev) + {generatedAt: $timestamp};

    (
      .[$rev] = currentRecord
      | to_entries
      | sort_by(.value.generatedAt // "")
      | reverse
      | .[:$limit]
      | from_entries
    )
  ' "$old_state" > "$new_state"

putStateFile "$state_name" "$new_state"

echo "Recorded HCI deployables state: $state_name"
jq -r --arg rev "$rev" '.[$rev] | "  \($rev) " + (.deployables | join(", "))' "$new_state"
