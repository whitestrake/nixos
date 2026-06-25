#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-}"
host_build_json="${HOST_BUILD_JSON:-}"
state_history_limit="${HCI_BUILT_STATE_HISTORY_LIMIT:-10}"

if [ -z "$cache_name" ]; then
  echo "ERROR: CACHIX_CACHE_NAME is empty." >&2
  exit 1
fi

if [ -z "${CACHIX_AUTH_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_AUTH_TOKEN is empty." >&2
  exit 1
fi

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
  and (.buildPin | type == "string" and startswith("built-host-"))
  and (
    if .deployable then
      (.rollbackScript | type == "string" and startswith("/nix/store/"))
      and (.rollbackPin | type == "string" and startswith("built-rollback-"))
    else
      true
    end
  )
'

if ! printf '%s\n' "$host_build_json" | jq -e "$required_filter" >/dev/null; then
  echo "ERROR: HOST_BUILD_JSON is malformed." >&2
  printf '%s\n' "$host_build_json" | jq . >&2 || printf '%s\n' "$host_build_json" >&2
  exit 1
fi

host="$(printf '%s\n' "$host_build_json" | jq -r '.host')"
rev="$(printf '%s\n' "$host_build_json" | jq -r '.rev')"
store_path="$(printf '%s\n' "$host_build_json" | jq -r '.storePath')"
build_pin="$(printf '%s\n' "$host_build_json" | jq -r '.buildPin')"
deployable="$(printf '%s\n' "$host_build_json" | jq -r '.deployable')"
state_name="built-host-$host.json"
work_dir="$(mktemp -d)"
old_state="$work_dir/state-old.json"
new_state="$work_dir/state-new.json"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

with_retry() {
  local n=1 max=3 delay=2
  while true; do
    if "$@"; then
      break
    fi

    if [[ $n -lt $max ]]; then
      n=$((n + 1))
      echo "Command failed. Attempt $n/$max in $delay seconds:" >&2
      sleep "$delay"
      delay=$((delay * 2))
    else
      echo "Command failed after $n attempts." >&2
      return 1
    fi
  done
}

fetch_pins() {
  with_retry curl -fsS \
    -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
    "https://app.cachix.org/api/v1/cache/$cache_name/pin" \
    | jq -e 'if type == "array" then . else error("Cachix pin API did not return an array") end'
}

pin_path() {
  local pin_name="$1"
  jq -r \
    --arg name "$pin_name" \
    'map(select(.name == $name))[0].lastRevision.storePath // ""' \
    <<< "$pins"
}

pin_state() {
  local pin_name="$1"
  local path="$2"
  local payload

  case "$pin_name" in
    built-host-*|built-rollback-*)
      ;;
    *)
      echo "ERROR: refusing to update unexpected pin: $pin_name" >&2
      return 1
      ;;
  esac

  payload="$(
    jq -n \
      --arg name "$pin_name" \
      --arg storePath "$path" \
      '{name: $name, storePath: $storePath, artifacts: [], keep: null}'
  )"

  with_retry curl -fsS \
    -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "https://app.cachix.org/api/v1/cache/$cache_name/pin" \
    >/dev/null
}

pins="$(fetch_pins)"
previous_built="$(pin_path "$build_pin")"

if [ "$deployable" = "true" ]; then
  rollback_script="$(printf '%s\n' "$host_build_json" | jq -r '.rollbackScript')"
  rollback_pin="$(printf '%s\n' "$host_build_json" | jq -r '.rollbackPin')"
  previous_rollback="$(pin_path "$rollback_pin")"

  if [ "$previous_rollback" = "$rollback_script" ]; then
    echo "Rollback script already pinned for $host:"
    echo "  $rollback_pin -> $rollback_script"
  else
    echo "Rollback script differs for $host:"
    echo "  previous: ${previous_rollback:-[none]}"
    echo "  current:  $rollback_script"

    echo "Pinning rollback script: $rollback_pin -> $rollback_script"
    pin_state "$rollback_pin" "$rollback_script"
  fi
fi

if [ "$previous_built" = "$store_path" ]; then
  echo "Built state already pinned for $host:"
  echo "  $build_pin -> $store_path"
else
  echo "Built state differs for $host:"
  echo "  previous: ${previous_built:-[none]}"
  echo "  current:  $store_path"

  echo "Pinning built state: $build_pin -> $store_path"
  pin_state "$build_pin" "$store_path"
fi

getStateFile "$state_name" "$old_state"

if [ -e "$old_state" ] && ! jq -e 'type == "object"' "$old_state" >/dev/null; then
  echo "Existing state $state_name is malformed; replacing it." >&2
  rm -f "$old_state"
fi

if [ ! -e "$old_state" ]; then
  jq -n --arg host "$host" '{($host): {}}' > "$old_state"
fi

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq \
  --argjson current "$host_build_json" \
  --arg host "$host" \
  --arg rev "$rev" \
  --arg timestamp "$timestamp" \
  --argjson limit "$state_history_limit" \
  '
    def currentRecord:
      $current | del(.host, .rev, .buildPin) + {builtAt: $timestamp};

    def legacyEntries:
      if (.builds | type) == "array" then
        .builds
        | map(select((.host // $host) == $host and (.rev // "") != ""))
        | map({key: .rev, value: (del(.host, .rev, .buildPin))})
      else
        []
      end;

    def keyedEntries:
      if (.[$host] | type) == "object" then
        .[$host] | to_entries
      else
        []
      end;

    {
      ($host): (
        ([{key: $rev, value: currentRecord}] + keyedEntries + legacyEntries)
        | reduce .[] as $item (
            [];
            if any(.[]; .key == $item.key) then
              .
            else
              . + [$item]
            end
          )
        | sort_by(.value.builtAt // "")
        | reverse
        | .[:$limit]
        | from_entries
      )
    }
  ' "$old_state" > "$new_state"

putStateFile "$state_name" "$new_state"

echo "Recorded HCI build state: $state_name"
jq -r --arg host "$host" --arg rev "$rev" '.[$host][$rev] | "  \($rev) \(.storePath)"' "$new_state"
