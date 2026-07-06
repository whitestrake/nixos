#!/usr/bin/env bash
set -euo pipefail

github_api_url="${GITHUB_API_URL:-https://api.github.com}"
github_repository="${GITHUB_REPOSITORY:-whitestrake/nixos}"
workflow="${CACHIX_DEPLOY_WORKFLOW:-continuous-deployment.yml}"
rev="${CACHIX_DEPLOY_REV:-${GITHUB_SHA:-}}"
branch="${CACHIX_DEPLOY_BRANCH:-master}"
source="${CACHIX_DEPLOY_SOURCE:-github-actions}"
force="${CACHIX_DEPLOY_FORCE:-false}"
matrix_file="${CACHIX_DEPLOY_MATRIX_FILE:-}"
deployment_token="${GITHUB_DEPLOYMENT_TOKEN:-${GH_TOKEN:-}}"

if [ -z "$rev" ]; then
  echo "ERROR: CACHIX_DEPLOY_REV or GITHUB_SHA must be set." >&2
  exit 1
fi

if [ -z "$matrix_file" ]; then
  echo "ERROR: CACHIX_DEPLOY_MATRIX_FILE is empty." >&2
  exit 1
fi

case "$force" in
  true|false)
    ;;
  *)
    echo "ERROR: CACHIX_DEPLOY_FORCE must be true or false." >&2
    exit 1
    ;;
esac

if [ ! -r "$matrix_file" ]; then
  echo "ERROR: CACHIX_DEPLOY_MATRIX_FILE is not readable: $matrix_file" >&2
  exit 1
fi

if [ -z "$deployment_token" ]; then
  echo "ERROR: GITHUB_DEPLOYMENT_TOKEN or GH_TOKEN is empty." >&2
  exit 1
fi

IFS=/ read -r github_owner github_repo github_extra <<< "$github_repository"
if [ -z "${github_owner:-}" ] || [ -z "${github_repo:-}" ] || [ -n "${github_extra:-}" ]; then
  echo "ERROR: GITHUB_REPOSITORY must have the form owner/repo, got: $github_repository" >&2
  exit 1
fi

if ! jq -e '
  type == "object"
  and (.include | type == "array" and length > 0)
  and all(.include[]; (
    (.host | type == "string" and length > 0)
    and (.system | type == "string" and length > 0)
    and (.storePath | type == "string" and startswith("/nix/store/"))
    and (.rollbackScript | type == "string" and startswith("/nix/store/"))
  ))
' "$matrix_file" >/dev/null; then
  echo "ERROR: deployment matrix is malformed or empty: $matrix_file" >&2
  jq . "$matrix_file" >&2 || true
  exit 1
fi

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

if [ "$source" = "hercules-ci" ]; then
  current_rev="$(
    with_retry curl -fsS \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $deployment_token" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$github_api_url/repos/$github_repository/git/ref/heads/$branch" \
      | jq -r '.object.sha // empty'
  )"

  if [ -z "$current_rev" ]; then
    echo "ERROR: GitHub branch ref did not include a commit sha for $branch." >&2
    exit 1
  fi

  if [ "$rev" != "$current_rev" ]; then
    echo "Skipping stale HCI deploy:"
    echo "  deployment sha: $rev"
    echo "  current $branch: $current_rev"
    exit 0
  fi
fi

payload="$(
  jq -n \
    --arg rev "$rev" \
    --arg branch "$branch" \
    --arg source "$source" \
    --arg force "$force" \
    --arg matrix "$(jq -c . "$matrix_file")" \
    '{
      ref: $branch,
      inputs: {
        deployment_sha: $rev,
        deployment_source: $source,
        force: $force,
        matrix: $matrix
      }
    }'
)"

echo "Dispatching Cachix deploy workflow for changed hosts:"
jq -r '.include[] | "  " + .host + " -> " + .storePath' "$matrix_file"

with_retry curl -fsS \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $deployment_token" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  --data "$payload" \
  "$github_api_url/repos/$github_repository/actions/workflows/$workflow/dispatches"

echo "Dispatched $workflow at $branch for $rev."
