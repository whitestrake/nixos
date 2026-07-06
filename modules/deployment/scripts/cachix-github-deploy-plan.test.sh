#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/cachix-github-deploy-plan.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin" "$tmp_dir/out"

cat > "$tmp_dir/bin/nix" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'eval --accept-flake-config --json .#deployment.deployables')
    jq -cn '{
      jaeger: {
        system: "aarch64-linux",
        storePath: "/nix/store/current-jaeger",
        rollbackScript: "/nix/store/rollback-jaeger",
        deployPin: "deployed-host-jaeger"
      },
      oculus: {
        system: "x86_64-linux",
        storePath: "/nix/store/current-oculus",
        rollbackScript: "/nix/store/rollback-oculus",
        deployPin: "deployed-host-oculus"
      }
    }'
    ;;
  path-info*)
    printf '%s\n' "$*" > "${NIX_PATH_INFO_LOG:?}"
    ;;
  *)
    echo "unexpected nix args: $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$tmp_dir/bin/nix"

export PATH="$tmp_dir/bin:$PATH"
export CACHIX_CACHE_NAME=whitestrake
export CACHIX_AUTH_TOKEN=dummy
export CACHIX_DEPLOY_REV=deadbeef
export CACHIX_DEPLOY_HOSTS=all
export CACHIX_DEPLOY_FORCE=false
export CACHIX_DEPLOY_OUTPUT_DIR="$tmp_dir/out"
export NIX_PATH_INFO_LOG="$tmp_dir/path-info.log"
export CACHIX_PIN_FUNCTIONS_SCRIPT="$tmp_dir/pins.sh"

cat > "$CACHIX_PIN_FUNCTIONS_SCRIPT" <<'SH'
cachix_fetch_pins() {
  jq -cn '[{name: "deployed-host-oculus", lastRevision: {storePath: "/nix/store/current-oculus"}}]'
}
cachix_pin_path() {
  jq -r --arg name "$2" 'map(select(.name == $name))[0].lastRevision.storePath // ""' <<< "$1"
}
cachix_verify_store_paths() {
  nix path-info --store "https://$1.cachix.org" "${@:2}" >/dev/null
}
SH

bash "$script"

matrix="$(jq -c . "$tmp_dir/out/deploy-matrix.json")"
expected='{"include":[{"host":"jaeger","system":"aarch64-linux","storePath":"/nix/store/current-jaeger","rollbackScript":"/nix/store/rollback-jaeger"}]}'
if [ "$matrix" != "$expected" ]; then
  printf 'expected matrix: %s\nactual matrix:   %s\n' "$expected" "$matrix" >&2
  exit 1
fi

if ! grep -q '/nix/store/current-jaeger' "$NIX_PATH_INFO_LOG"; then
  echo "expected manual planner to verify selected store paths in Cachix" >&2
  exit 1
fi
