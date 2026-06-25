#!/usr/bin/env bash
set -euo pipefail

host_build_json="${HOST_BUILD_JSON:-}"
state_history_limit="${HCI_BUILT_STATE_HISTORY_LIMIT:-10}"

if [ -z "$host_build_json" ]; then
  echo "ERROR: HOST_BUILD_JSON is empty." >&2
  exit 1
fi

if ! [[ "$state_history_limit" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HCI_BUILT_STATE_HISTORY_LIMIT must be a positive integer." >&2
  exit 1
fi

required_filter='
  type == "object"
  and (.host | type == "string" and length > 0)
  and (.kind | type == "string" and length > 0)
  and (.system | type == "string" and length > 0)
  and (.storePath | type == "string" and startswith("/nix/store/"))
  and (.ref | type == "string" and length > 0)
  and (.rev | type == "string" and length > 0)
  and (.jobName | type == "string" and length > 0)
  and (.deployable | type == "boolean")
'

if ! printf '%s\n' "$host_build_json" | jq -e "$required_filter" >/dev/null; then
  echo "ERROR: HOST_BUILD_JSON is malformed." >&2
  printf '%s\n' "$host_build_json" | jq . >&2 || printf '%s\n' "$host_build_json" >&2
  exit 1
fi

host="$(printf '%s\n' "$host_build_json" | jq -r '.host')"
state_name="built-host/$host.json"
work_dir="$(mktemp -d)"
old_state="$work_dir/state-old.json"
new_state="$work_dir/state-new.json"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

getStateFile "$state_name" "$old_state"

if [ -e "$old_state" ] && ! jq -e 'type == "object" and (.builds | type == "array")' "$old_state" >/dev/null; then
  echo "Existing state $state_name is malformed; replacing it." >&2
  rm -f "$old_state"
fi

if [ ! -e "$old_state" ]; then
  jq -n --arg host "$host" '{host: $host, builds: []}' > "$old_state"
fi

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq \
  --argjson current "$host_build_json" \
  --arg timestamp "$timestamp" \
  --argjson limit "$state_history_limit" \
  '
    .host = $current.host
    | .builds = (
        (
          [
            ($current + {builtAt: $timestamp})
          ]
          + (.builds // [])
        )
        | reduce .[] as $item (
            [];
            if any(.[]; .rev == $item.rev and .storePath == $item.storePath) then
              .
            else
              . + [$item]
            end
          )
        | .[:$limit]
      )
  ' "$old_state" > "$new_state"

putStateFile "$state_name" "$new_state"

echo "Recorded HCI build state: $state_name"
jq -r '.builds[0] | "  \(.rev) \(.storePath)"' "$new_state"
