#!/usr/bin/env bash

cachix_with_retry() {
  local n delay=2
  for n in 1 2 3; do
    "$@" && return 0
    [ "$n" = 3 ] && break
    echo "Command failed. Attempt $((n + 1))/3 in $delay seconds:" >&2
    sleep "$delay"
    delay=$((delay * 2))
  done
  echo "Command failed after 3 attempts." >&2
  return 1
}

cachix_fetch_pins() {
  cachix_with_retry curl -fsS \
    -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
    "https://app.cachix.org/api/v1/cache/$1/pin" \
    | jq -e 'if type == "array" then . else error("Cachix pin API did not return an array") end'
}

cachix_pin_path() {
  jq -r --arg name "$2" \
    'map(select(.name == $name))[0].lastRevision.storePath // ""' \
    <<< "$1"
}

cachix_pin_payload() {
  jq -n \
    --arg name "$1" \
    --arg storePath "$2" \
    --argjson keepRevisions "$3" \
    '{name: $name, storePath: $storePath, artifacts: [], keep: {tag: "Revisions", contents: $keepRevisions}}'
}

cachix_pin_store_path() {
  cachix_with_retry curl -fsS \
    -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$(cachix_pin_payload "$2" "$3" "$4")" \
    "https://app.cachix.org/api/v1/cache/$1/pin" \
    >/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" == "--self-test" ]]; then
  set -euo pipefail
  pins='[{"name":"built-host-pascal","lastRevision":{"storePath":"/nix/store/example-pascal"}}]'
  test "$(cachix_pin_path "$pins" built-host-pascal)" = "/nix/store/example-pascal"
  test -z "$(cachix_pin_path "$pins" missing)"

  payload="$(cachix_pin_payload built-host-pascal /nix/store/example-pascal 10)"
  jq -e '
    .name == "built-host-pascal"
    and .storePath == "/nix/store/example-pascal"
    and .keep.tag == "Revisions"
    and .keep.contents == 10
  ' <<< "$payload" >/dev/null

  CACHIX_AUTH_TOKEN=test-token
  curl_args=()
  curl() {
    curl_args=("$@")
  }

  cachix_pin_store_path whitestrake built-host-pascal /nix/store/example-pascal 10
  test "${#curl_args[@]}" = 8
  test "${curl_args[2]}|${curl_args[4]}|${curl_args[5]}|${curl_args[7]}" = "Authorization: Bearer test-token|Content-Type: application/json|--data|https://app.cachix.org/api/v1/cache/whitestrake/pin"
  jq -e '
    .name == "built-host-pascal"
    and .storePath == "/nix/store/example-pascal"
  ' <<< "${curl_args[6]}" >/dev/null
fi
