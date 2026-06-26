#!/usr/bin/env bash
set -euo pipefail

cache_name="${CACHIX_CACHE_NAME:-}"
deployables_json="${DEPLOYABLES_JSON:-}"
state_history_limit="${HCI_DEPLOYABLES_HISTORY_LIMIT:-10}"
built_pin_keep_revisions="${CACHIX_BUILT_PIN_KEEP_REVISIONS:-10}"
state_name="deployables.json"

if [ -z "$cache_name" ]; then
  echo "ERROR: CACHIX_CACHE_NAME is empty." >&2
  exit 1
fi

if [ -z "${CACHIX_AUTH_TOKEN:-}" ]; then
  echo "ERROR: CACHIX_AUTH_TOKEN is empty." >&2
  exit 1
fi

if [ -z "$deployables_json" ]; then
  echo "ERROR: DEPLOYABLES_JSON is empty." >&2
  exit 1
fi

if ! [[ "$state_history_limit" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HCI_DEPLOYABLES_HISTORY_LIMIT must be a positive integer." >&2
  exit 1
fi

if ! [[ "$built_pin_keep_revisions" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: CACHIX_BUILT_PIN_KEEP_REVISIONS must be a positive integer." >&2
  exit 1
fi

required_filter='
  . as $root
  | type == "object"
    and (.rev | type == "string" and length > 0)
    and (.shortRev | type == "string" and length > 0)
    and (.branch | type == "string" and length > 0)
    and (.ref | type == "string" and length > 0)
    and (.deployables | type == "array" and length > 0)
    and all(.deployables[]; type == "string" and length > 0)
    and (.hosts | type == "object")
    and all(
      .deployables[];
      . as $host
      | ($root.hosts[$host] | type == "object")
      and ($root.hosts[$host].kind | type == "string" and length > 0)
      and ($root.hosts[$host].jobName | type == "string" and length > 0)
      and ($root.hosts[$host].system | type == "string" and length > 0)
      and ($root.hosts[$host].storePath | type == "string" and startswith("/nix/store/"))
      and ($root.hosts[$host].buildPin | type == "string" and startswith("built-host-"))
      and ($root.hosts[$host].rollbackScript | type == "string" and startswith("/nix/store/"))
      and ($root.hosts[$host].rollbackPin | type == "string" and startswith("built-rollback-"))
      and ($root.hosts[$host].deployPin | type == "string" and startswith("deployed-host-"))
    )
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
      --argjson keepRevisions "$built_pin_keep_revisions" \
      '{name: $name, storePath: $storePath, artifacts: [], keep: {tag: "Revisions", contents: $keepRevisions}}'
  )"

  with_retry curl -fsS \
    -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "https://app.cachix.org/api/v1/cache/$cache_name/pin" \
    >/dev/null
}

pins="$(fetch_pins)"

while IFS=$'\t' read -r host build_pin store_path rollback_pin rollback_script; do
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

  previous_built="$(pin_path "$build_pin")"
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
done < <(
  printf '%s\n' "$deployables_json" \
    | jq -r '
        .deployables[] as $host
        | .hosts[$host]
        | [
            $host,
            .buildPin,
            .storePath,
            .rollbackPin,
            .rollbackScript
          ]
        | @tsv
      '
)

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
