#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$script_dir/hci-deliverables-state-script.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"

cat > "$tmp_dir/bin/curl" <<'SH'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  */site/github/account/whitestrake/project/nixos)
    jq -cn '{owner: {id: "account-uuid"}}'
    ;;
  *'/project/nixos/jobs?'*)
    jq -cn '{
      items: [
        {
          id: "job-jaeger",
          index: 100,
          jobName: "20-nixosConfiguration-jaeger",
          jobPhase: "Done",
          jobStatus: "Success",
          evaluationStatus: "Success",
          derivationStatus: "Success",
          effectsStatus: "Success",
          source: {revision: "deadbeef"}
        }
      ],
      more: false
    }'
    ;;
  */jobs/job-jaeger/evaluation)
    jq -cn '{
      attributes: [
        {
          path: ["nixosConfigurations", "jaeger", "config", "system", "build", "toplevel"],
          value: {Ok: {derivationPath: "/nix/store/top-jaeger.drv", status: "BuildSuccess"}}
        },
        {
          path: ["packages", "aarch64-linux", "deploy-health-rollback-script-jaeger"],
          value: {Ok: {derivationPath: "/nix/store/rollback-jaeger.drv", status: "BuildSuccess"}}
        }
      ]
    }'
    ;;
  *'/derivations/'*top-jaeger*)
    jq -cn '{status: "BuildSuccess", outputs: [{outputName: "out", outputPath: "/nix/store/current-jaeger"}]}'
    ;;
  *'/derivations/'*rollback-jaeger*)
    jq -cn '{status: "BuildSuccess", outputs: [{outputName: "out", outputPath: "/nix/store/rollback-jaeger"}]}'
    ;;
  */repos/whitestrake/nixos/git/ref/heads/master)
    jq -cn '{object: {sha: "deadbeef"}}'
    ;;
  */actions/workflows/continuous-deployment.yml/dispatches)
    printf '%s\n' "$*" > "${DISPATCH_LOG:?}"
    ;;
  *)
    echo "unexpected curl URL: $url" >&2
    exit 1
    ;;
esac
SH
chmod +x "$tmp_dir/bin/curl"

export PATH="$tmp_dir/bin:$PATH"
export CACHIX_CACHE_NAME=whitestrake
export CACHIX_AUTH_TOKEN=dummy
export GITHUB_TOKEN=status-token
export GITHUB_DEPLOYMENT_TOKEN=deploy-token
export GITHUB_REPOSITORY=whitestrake/nixos
export HCI_DEPLOYMENT_REV=deadbeef
export HCI_DEPLOYMENT_BRANCH=master
export HCI_DEPLOYMENT_MODE=production
export HCI_CREATE_GITHUB_DEPLOYMENT=true
export HCI_REQUIRED_JOB_NAMES='["20-nixosConfiguration-jaeger"]'
export HCI_DEPLOYABLE_JOBS='[{"host":"jaeger","system":"aarch64-linux","jobName":"20-nixosConfiguration-jaeger","toplevelAttrPath":["nixosConfigurations","jaeger","config","system","build","toplevel"],"rollbackAttrPath":["packages","aarch64-linux","deploy-health-rollback-script-jaeger"],"deployPin":"deployed-host-jaeger"}]'
export CACHIX_PIN_FUNCTIONS_SCRIPT="$tmp_dir/pins.sh"
export CACHIX_CREATE_GITHUB_DEPLOYMENT_SCRIPT="$script_dir/cachix-create-github-deployment.sh"
export DISPATCH_LOG="$tmp_dir/dispatch.log"
export CI_GATE_HCI_ALLOW_ENV_TOKEN=true
export HERCULES_CI_TOKEN=dummy

cat > "$CACHIX_PIN_FUNCTIONS_SCRIPT" <<'SH'
cachix_fetch_pins() {
  jq -cn '[]'
}
cachix_pin_path() {
  jq -r --arg name "$2" 'map(select(.name == $name))[0].lastRevision.storePath // ""' <<< "$1"
}
SH

bash "$script"

if [ ! -s "$DISPATCH_LOG" ]; then
  echo "expected HCI dispatcher to call GitHub workflow dispatch" >&2
  exit 1
fi
