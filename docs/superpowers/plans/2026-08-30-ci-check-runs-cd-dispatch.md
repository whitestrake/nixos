# CI Check Runs and CD Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish informational per-output CI check runs and dispatch changed Cachix deployments as a separate CD workflow.

**Architecture:** A Python standard-library wrapper owns each existing Nix Fast Build subprocess, translates its JSONL events into best-effort GitHub Check Runs, and returns the subprocess status unchanged. `CI / Completed` retains the proven Cachix pin comparison, but directly dispatches the shared deployment workflow only when its matrix is non-empty.

**Tech Stack:** GitHub Actions YAML, Python 3 standard library, Bash, jq, Nix Fast Build 1.6.0, GitHub REST Checks and workflow-dispatch APIs.

**Spec:** `docs/superpowers/specs/2026-08-30-ci-check-runs-cd-dispatch-design.md`

## Global Constraints

- Preserve the existing uncommitted cache-lane changes before editing overlapping workflow files.
- Synthetic check publication is informational and must never change the Nix Fast Build exit status.
- Use exact synthetic names: `CI / nixosConfiguration <name>`, `CI / darwinConfiguration <name>`, and `CI / check <name>`.
- Do not publish synthetic checks for `deploy-health-rollback-script-*`.
- Use successful `EVAL` as the temporary `in_progress` transition and terminal `BUILD` as completion.
- Keep `CI / Completed` as the authoritative CI gate.
- Dispatch CD only on master, only for a non-empty Cachix deployed-pin difference matrix, and only after the stale-revision check.
- Keep Manual Deployment unchanged and retain `workflow_call` on the shared deployment workflow.
- Add no Python or marketplace dependencies.
- Do not push or dispatch workflows during local implementation.

---

### Task 1: Preserve the completed cache-lane implementation

**Files:**
- Modify: `.github/actions/nix-root-build/action.yml`
- Modify: `.github/workflows/continuous-integration.yml`
- Modify: `.github/workflows/github-cache-maintenance.yml`
- Modify: `.github/workflows/github-ci.yml`
- Modify: `modules/ci.nix`

**Interfaces:**
- Consumes: the existing working-tree changes already validated in this branch.
- Produces: a clean baseline commit containing `ci.configurations`, NFB-rooted cache lanes, NFB fingerprinting, and Darwin's rooted-NFB fallback.

- [ ] **Step 1: Re-run the narrow target membership evaluation**

Run:

```bash
nix eval --json .#ci.configurations --apply 'builtins.mapAttrs (_: builtins.attrNames)'
```

Expected:

```json
{"aarch64-darwin":["andred"],"aarch64-linux":["jaeger"],"x86_64-linux":["kronos","legion","oculus","omnius","onager","orthus","pascal","rapier","sortie"]}
```

- [ ] **Step 2: Re-run workflow and formatting validation**

Run:

```bash
nix shell nixpkgs#actionlint nixpkgs#shellcheck -c actionlint
nix build .#checks.aarch64-darwin.treefmt --no-link
git diff --check
```

Expected: all commands exit zero.

- [ ] **Step 3: Commit only the cache-lane implementation**

Run:

```bash
git add \
  .github/actions/nix-root-build/action.yml \
  .github/workflows/continuous-integration.yml \
  .github/workflows/github-cache-maintenance.yml \
  .github/workflows/github-ci.yml \
  modules/ci.nix
git commit -m "feat(ci): root nix-fast-build in cache lanes"
```

Expected: the working tree retains only the ignored implementation-plan document.

---

### Task 2: Implement the best-effort NFB Check Run publisher

**Files:**
- Create: `.github/scripts/nix_fast_build_checks.py`
- Create: `.github/scripts/test_nix_fast_build_checks.py`

**Interfaces:**
- Consumes: CLI `--group linux|darwin -- <nix-fast-build command...>` and the standard `GITHUB_TOKEN`, `GITHUB_REPOSITORY`, `GITHUB_SHA`, `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`, and `GITHUB_SERVER_URL` environment variables.
- Produces: `check_name(group: str, attr: str) -> str | None`, `CheckPublisher.handle(event: dict) -> None`, `CheckPublisher.finalize(conclusion: str) -> None`, and `run(command: list[str], publisher: CheckPublisher) -> int`.

- [ ] **Step 1: Write the failing classification and lifecycle tests**

Create `.github/scripts/test_nix_fast_build_checks.py` with standard-library `unittest`. Cover these exact assertions:

```python
from nix_fast_build_checks import CheckPublisher, check_name, run


class FakeChecks:
    def __init__(self, fail=False):
        self.fail = fail
        self.created = []
        self.updated = []

    def create(self, **payload):
        if self.fail:
            raise RuntimeError("API unavailable")
        self.created.append(payload)
        return len(self.created)

    def update(self, check_id, **payload):
        if self.fail:
            raise RuntimeError("API unavailable")
        self.updated.append((check_id, payload))


class CheckNameTests(unittest.TestCase):
    def test_names(self):
        self.assertEqual(
            check_name("linux", "omnius"),
            "CI / nixosConfiguration omnius",
        )
        self.assertEqual(
            check_name("darwin", "andred"),
            "CI / darwinConfiguration andred",
        )
        self.assertEqual(
            check_name("linux", "check-treefmt"),
            "CI / check treefmt",
        )
        self.assertIsNone(
            check_name("linux", "deploy-health-rollback-script-x86_64-linux")
        )
```

Add lifecycle tests that pass successful and failed `EVAL`/`BUILD` dictionaries to `CheckPublisher.handle`, assert the corresponding create/update payloads, and assert `run` returns a fake subprocess's non-zero status even when `FakeChecks(fail=True)` raises.

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
python3 -m unittest discover -s .github/scripts -p 'test_nix_fast_build_checks.py' -v
```

Expected: import failure because `nix_fast_build_checks.py` does not exist.

- [ ] **Step 3: Implement the publisher**

Create `.github/scripts/nix_fast_build_checks.py` with:

```python
def check_name(group, attr):
    if attr.startswith("deploy-health-rollback-script-"):
        return None
    if attr.startswith("check-"):
        return f"CI / check {attr.removeprefix('check-')}"
    kind = {
        "linux": "nixosConfiguration",
        "darwin": "darwinConfiguration",
    }[group]
    return f"CI / {kind} {attr}"
```

Implement a `GitHubChecks` REST client using `urllib.request`:

- `POST /repos/{repository}/check-runs` for creation;
- `PATCH /repos/{repository}/check-runs/{id}` for completion;
- headers `Authorization: Bearer ...`, `Accept: application/vnd.github+json`, and `X-GitHub-Api-Version: 2022-11-28`;
- three serial attempts with `Retry-After` or delays of two and four seconds;
- after the final failure, set `disabled = True`, emit one `::warning`, and make later calls no-ops.

Implement `CheckPublisher` so a successful `EVAL` creates:

```json
{
  "name": "CI / nixosConfiguration omnius",
  "head_sha": "<GITHUB_SHA>",
  "status": "in_progress",
  "started_at": "<UTC ISO-8601>",
  "external_id": "nfb:<run-id>:<attempt>:linux:omnius",
  "details_url": "<server>/<repository>/actions/runs/<run-id>/attempts/<attempt>"
}
```

A terminal event updates the saved numeric ID with `status: completed`, a `success` or `failure` conclusion, `completed_at`, and a short output title/summary. Failed evaluations are created directly as completed failures.

Implement `run` with `subprocess.Popen(stdout=subprocess.PIPE, text=True)`. Append `--stream-json-lines` to the supplied NFB command, inherit stderr, decode each stdout line with `json.loads`, and pass it to `publisher.handle`. Preserve the child return code. On normal exit, call `publisher.finalize("failure")`; after SIGINT or SIGTERM, call `publisher.finalize("cancelled")`.

- [ ] **Step 4: Run and fix the focused tests**

Run:

```bash
python3 -m unittest discover -s .github/scripts -p 'test_nix_fast_build_checks.py' -v
```

Expected: all tests pass, including API failure not changing the fake NFB status.

- [ ] **Step 5: Format and lint the Python**

Run:

```bash
nix fmt
python3 -m unittest discover -s .github/scripts -p 'test_nix_fast_build_checks.py' -v
```

Expected: Ruff formatting/checking succeeds through treefmt and all tests remain green.

- [ ] **Step 6: Commit the publisher**

Run:

```bash
git add \
  .github/scripts/nix_fast_build_checks.py \
  .github/scripts/test_nix_fast_build_checks.py
git commit -m "feat(ci): publish nix-fast-build check runs"
```

---

### Task 3: Wire synthetic checks into CI

**Files:**
- Modify: `.github/workflows/continuous-integration.yml`

**Interfaces:**
- Consumes: `.github/scripts/nix_fast_build_checks.py --group linux|darwin -- <command...>`.
- Produces: native checks `CI / Linux`, `CI / Darwin`, `CI / Completed` and informational per-output checks with the exact names in the global constraints.

- [ ] **Step 1: Rename the workflow and completion job**

Change:

```yaml
name: "CI"
```

and:

```yaml
complete:
  name: "Completed"
```

Remove the completion job's obsolete `deploy` and `deployment-matrix` outputs after Task 4 replaces the reusable-workflow handoff.

- [ ] **Step 2: Add narrow Check Run permissions**

Add to both `linux` and `darwin` jobs:

```yaml
permissions:
  checks: write
  contents: read
```

Do not grant `checks: write` to the completion job.

- [ ] **Step 3: Wrap the Linux NFB command**

Set the build step environment:

```yaml
env:
  GITHUB_TOKEN: ${{ github.token }}
```

Replace the direct invocation with:

```bash
python3 .github/scripts/nix_fast_build_checks.py --group linux -- \
  nix run --inputs-from . nixpkgs-unstable#nix-fast-build -- \
    --flake .#ci.linux \
    --systems 'x86_64-linux aarch64-linux' \
    --store ssh-ng://eu.nixbuild.net \
    --option builders '' \
    --option max-jobs 2 \
    --no-nom \
    --retries 2 \
    --result-file "$RUNNER_TEMP/ci-linux-results.json" \
    -j 50
```

Do not remove the existing result-file parsing or rollback-output validation.

- [ ] **Step 4: Wrap the Darwin NFB command**

Set the Darwin build step's `GITHUB_TOKEN` environment and invoke:

```bash
python3 .github/scripts/nix_fast_build_checks.py --group darwin -- \
  "${nix_fast_build[@]}" \
    --flake .#ci.darwin \
    --systems aarch64-darwin \
    --no-nom \
    --result-file "$RUNNER_TEMP/ci-darwin-results.json" \
    -j 50
```

Do not change the rooted-binary selection or fallback.

- [ ] **Step 5: Validate workflow syntax**

Run:

```bash
nix shell nixpkgs#actionlint nixpkgs#shellcheck -c actionlint .github/workflows/continuous-integration.yml
python3 -m unittest discover -s .github/scripts -p 'test_nix_fast_build_checks.py' -v
```

Expected: both commands pass.

- [ ] **Step 6: Commit the CI integration**

Run:

```bash
git add .github/workflows/continuous-integration.yml
git commit -m "feat(ci): expose per-output check runs"
```

---

### Task 4: Dispatch changed deployments as a separate CD workflow

**Files:**
- Modify: `.github/workflows/continuous-integration.yml`
- Modify: `.github/workflows/continuous-deployment.yml`
- Preserve: `.github/workflows/manual-deployment.yml`

**Interfaces:**
- Consumes: the existing compact `{include: [...]}` deployment matrix and GitHub's workflow-dispatch endpoint through `gh workflow run`.
- Produces: a separate workflow run named `CD` with `CD / Preflight` and `CD / Deploy <host>` jobs.

- [ ] **Step 1: Add the machine entrypoint without changing the human entrypoint**

Rename the workflow:

```yaml
name: "CD"
```

Add `workflow_dispatch` inputs matching the existing `workflow_call` inputs exactly:

```yaml
workflow_dispatch:
  inputs:
    deployment_sha:
      description: "Commit SHA to deploy."
      required: true
      type: string
    deployment_source:
      description: "Deployment source label."
      required: true
      type: string
    matrix:
      description: "Deployment matrix JSON."
      required: true
      type: string
    force:
      description: "Redeploy even when deployed-host-* already matches the target."
      required: false
      default: false
      type: boolean
```

Retain the existing `workflow_call` block and secrets unchanged. Rename the preflight job display name to `Preflight`; retain `Deploy ${{ matrix.host }}`.

- [ ] **Step 2: Give only CI Completed dispatch authority**

Set the completion job permissions to:

```yaml
permissions:
  actions: write
  contents: read
```

Add `GH_TOKEN: ${{ github.token }}` to the promotion step environment.

- [ ] **Step 3: Replace the stapled reusable-workflow job with direct dispatch**

After the existing empty-matrix and stale-revision guards, compact and print the matrix, then call:

```bash
matrix="$(jq -c . <<< "$deployment_matrix")"
cachix_with_retry gh workflow run continuous-deployment.yml \
  --repo "$GITHUB_REPOSITORY" \
  --ref "$GITHUB_REF_NAME" \
  --raw-field deployment_sha="$GITHUB_SHA" \
  --raw-field deployment_source=continuous-integration \
  --raw-field force=false \
  --raw-field matrix="$matrix"
```

Delete the `deploy` reusable-workflow job from CI and delete completion outputs that served only that job. Do not change the Cachix pin comparison or built-pin promotion.

- [ ] **Step 4: Run a local empty/non-empty dispatch probe**

Run a shell probe with a mocked `gh` function and the same matrix-length guard:

```bash
bash -c '
set -euo pipefail
calls=0
gh() { calls=$((calls + 1)); }
dispatch() {
  local matrix="$1"
  [ "$(jq -r ".include | length" <<< "$matrix")" = 0 ] && return 0
  gh workflow run continuous-deployment.yml --raw-field matrix="$(jq -c . <<< "$matrix")"
}
dispatch "{\"include\":[]}"
[ "$calls" = 0 ]
dispatch "{\"include\":[{\"host\":\"omnius\"}]}"
[ "$calls" = 1 ]
'
```

Expected: exit zero, proving empty matrices do not dispatch and non-empty matrices dispatch once.

- [ ] **Step 5: Validate both workflow entrypoints**

Run:

```bash
nix shell nixpkgs#actionlint nixpkgs#shellcheck -c actionlint \
  .github/workflows/continuous-integration.yml \
  .github/workflows/continuous-deployment.yml \
  .github/workflows/manual-deployment.yml
```

Expected: all workflows pass, including Manual Deployment's retained reusable call.

- [ ] **Step 6: Commit the workflow separation**

Run:

```bash
git add \
  .github/workflows/continuous-integration.yml \
  .github/workflows/continuous-deployment.yml
git commit -m "feat(cd): dispatch changed deployments separately"
```

---

### Task 5: Integrated verification and handoff

**Files:**
- Verify all files changed by Tasks 1-4.

**Interfaces:**
- Consumes: the complete feature branch.
- Produces: local evidence suitable for a feature-branch CI run, without pushing or dispatching it.

- [ ] **Step 1: Run all local checks**

Run:

```bash
python3 -m unittest discover -s .github/scripts -p 'test_nix_fast_build_checks.py' -v
nix fmt
nix build .#checks.aarch64-darwin.treefmt --no-link
nix shell nixpkgs#actionlint nixpkgs#shellcheck -c actionlint
git diff --check
```

Expected: every command exits zero.

- [ ] **Step 2: Re-evaluate the narrow CI target**

Run:

```bash
nix eval --json .#ci.configurations --apply 'builtins.mapAttrs (_: builtins.attrNames)'
```

Expected: the same three-system host map recorded in Task 1.

- [ ] **Step 3: Review commit and working-tree state**

Run:

```bash
git status --short --branch
git log --oneline --decorate origin/master..HEAD
git diff origin/master...HEAD --check
```

Expected: implementation commits are present, no accidental files are staged, and only intentionally ignored planning material may remain untracked.

- [ ] **Step 4: Report the live-verification boundary**

Report that local implementation is complete but no push or workflow dispatch occurred. Recommend the next authorised sequence:

1. Push the feature branch.
2. Run CI and inspect all synthetic names and transitions.
3. Merge after review.
4. Observe the first non-empty master deployment as a separate CD run.
5. Restore branch protection on `CI / Completed`.
