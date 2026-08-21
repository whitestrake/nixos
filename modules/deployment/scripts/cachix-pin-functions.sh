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

cachix_verify_store_paths() {
  local cache_name="$1"
  shift

  if [ "$#" -eq 0 ]; then
    return 0
  fi

  cachix_with_retry nix path-info --store "https://$cache_name.cachix.org" "$@" >/dev/null
}

cachix_verify_store_paths_http() {
  local cache_name="$1"
  local narinfo narinfo_store_path store_hash store_path
  shift

  for store_path; do
    if [[ ! "$store_path" =~ ^/nix/store/([0-9abcdfghijklmnpqrsvwxyz]{32})-.+$ ]]; then
      echo "Invalid Nix store path: $store_path" >&2
      return 1
    fi
    store_hash="${BASH_REMATCH[1]}"
    narinfo="$(cachix_with_retry curl -fsS "https://$cache_name.cachix.org/$store_hash.narinfo")" ||
      return 1
    narinfo_store_path="$(sed -n 's/^StorePath: //p' <<< "$narinfo")"
    if [ "$narinfo_store_path" != "$store_path" ]; then
      echo "Cachix narinfo StorePath mismatch for $store_path: ${narinfo_store_path:-[missing]}" >&2
      return 1
    fi
  done
}
