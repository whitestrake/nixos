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
  local auth_header=()

  if [ -n "${CACHIX_AUTH_TOKEN:-}" ]; then
    auth_header=(-H "Authorization: Bearer $CACHIX_AUTH_TOKEN")
  fi

  cachix_with_retry curl -fsS \
    "${auth_header[@]}" \
    "https://app.cachix.org/api/v1/cache/$1/pin" \
    | jq -e 'if type == "array" then . else error("Cachix pin API did not return an array") end'
}

cachix_pin_path() {
  jq -r --arg name "$2" \
    'map(select(.name == $name))[0].lastRevision.storePath // ""' \
    <<< "$1"
}

cachix_pin_path_strict() {
  local pins="$1"
  local name="$2"
  local store_path

  store_path="$(
    jq -er --arg name "$name" '
      [ .[] | select(.name == $name) ] as $matches
      | if ($matches | length) != 1 then
          error("expected exactly one \($name) pin")
        elif (($matches[0].lastRevision.storePath // null) | type) != "string" then
          error("\($name) pin has no last revision store path")
        else
          $matches[0].lastRevision.storePath
        end
    ' <<< "$pins"
  )"

  if ! [[ "$store_path" =~ ^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$ ]]; then
    echo "ERROR: $name pin has an invalid last revision store path: $store_path" >&2
    return 1
  fi

  printf '%s\n' "$store_path"
}

cachix_pin_payload() {
  jq -n \
    --arg name "$1" \
    --arg storePath "$2" \
    --argjson keepRevisions "$3" \
    '{name: $name, storePath: $storePath, artifacts: [], keep: {tag: "Revisions", contents: $keepRevisions}}'
}

cachix_pin_store_path() {
  local pins

  if curl -fsS \
    -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$(cachix_pin_payload "$2" "$3" "$4")" \
    "https://app.cachix.org/api/v1/cache/$1/pin" \
    >/dev/null; then
    return 0
  fi

  echo "Cachix pin POST failed; reconciling the requested pin once." >&2
  pins="$(cachix_fetch_pins "$1")" || return 1
  if [ "$(cachix_pin_path "$pins" "$2")" = "$3" ]; then
    echo "Cachix pin reconciled after an ambiguous POST failure: $2 -> $3" >&2
    return 0
  fi

  echo "Cachix pin POST failed and the requested pin was not observed: $2 -> $3" >&2
  return 1
}

cachix_verify_store_paths() {
  local cache_name="$1"
  shift

  if [ "$#" -eq 0 ]; then
    return 0
  fi

  cachix_with_retry nix path-info --store "https://$cache_name.cachix.org" "$@" >/dev/null
}
