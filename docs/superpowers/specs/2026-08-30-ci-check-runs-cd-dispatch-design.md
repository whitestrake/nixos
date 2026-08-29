# CI Check Runs and CD Dispatch Design

## Purpose

Improve the visibility of the consolidated Continuous Integration workflow without
turning its individual Nix outputs into separate GitHub Actions jobs, and restore
Continuous Deployment as a separate workflow run.

The consolidated CI completion job remains the authoritative proof of success.
Synthetic per-output checks are informational and must not change the CI result.

## Naming

The Continuous Integration workflow is named `CI`, producing these native job
checks:

- `CI / Linux`
- `CI / Darwin`
- `CI / Completed`

Nix Fast Build produces these synthetic check names:

- NixOS configuration: `CI / nixosConfiguration <name>`
- Darwin configuration: `CI / darwinConfiguration <name>`
- Flake check: `CI / check <name>`

The `check-` attribute prefix is removed from the displayed check name. Internal
`deploy-health-rollback-script-*` outputs do not receive synthetic checks.

The Continuous Deployment workflow is named `CD`, producing:

- `CD / Preflight`
- `CD / Deploy <host>`

## Nix Fast Build Check Publisher

Add one Python standard-library wrapper around each existing CI Nix Fast Build
invocation. The wrapper launches Nix Fast Build as a subprocess with
`--stream-json-lines` while preserving the existing `--result-file` and all
existing command arguments.

Nix Fast Build stderr remains attached to the Actions log. The wrapper consumes
JSON Lines from stdout and maps events as follows:

| Nix Fast Build event | Synthetic check action |
| --- | --- |
| Successful configuration or check `EVAL` | Create `in_progress` |
| Failed configuration or check `EVAL` | Create completed `failure` |
| Successful `BUILD` | Complete as `success` |
| Failed terminal `BUILD` | Complete as `failure` |

Using `EVAL` as the start event is an intentional approximation until Nix Fast
Build exposes a structured build-start event.

The Linux publisher classifies ordinary attributes as `nixosConfiguration`,
`check-*` attributes as checks, and excludes rollback-script helpers. The Darwin
publisher classifies ordinary attributes as `darwinConfiguration`.

Check names remain stable. Each check includes an attempt-specific external ID
using the workflow run ID, run attempt, CI group, and attribute name. Its details
URL points to the Actions run.

### Publisher failure policy

GitHub check publication is best-effort:

- API mutations are serial.
- Transient failures receive a small bounded retry that honours `Retry-After`.
- A persistent API failure disables further publication for that job and emits
  one Actions warning.
- API failures never alter the Nix Fast Build subprocess exit status.
- On normal subprocess exit, any remaining in-progress checks are completed as
  failures because no terminal build event arrived.
- On cancellation signals, the wrapper makes a best-effort attempt to complete
  outstanding checks as cancelled.

Hard runner loss may still leave an informational check in progress. A separate
reconciliation workflow is out of scope until this is observed in practice.

The Linux and Darwin jobs receive only `contents: read` and `checks: write`.

## CI Completion and Deployment Planning

`CI / Completed` continues to:

1. Require successful Linux and Darwin jobs.
2. Combine and validate successful configuration records.
3. Validate deploy targets against those successful records.
4. Verify configuration and rollback paths in Cachix.
5. Fetch Cachix pins.
6. Update changed `built-host-*` pins.
7. Compare every deployable host's freshly built toplevel with its
   `deployed-host-*` pin.
8. Emit a compact deployment matrix containing only differences.

Feature branches retain the prospective matrix summary but do not promote or
dispatch. On master, the completion job verifies that the branch still points to
the run's commit before performing side effects.

An empty deployment matrix ends successfully without invoking CD. A non-empty
matrix is printed and passed directly to a workflow dispatch for
`continuous-deployment.yml`, together with:

- the deployment commit SHA;
- `deployment_source: continuous-integration`;
- `force: false`.

The completion job receives `actions: write` for this dispatch. The existing
bounded retry helper wraps the dispatch request.

## Shared Deployment Workflow

`continuous-deployment.yml` retains `workflow_call` for the existing Manual
Deployment workflow and adds `workflow_dispatch` for the machine-generated CI
handoff.

Manual Deployment remains unchanged as the human planner. CI Completed is the
automatic planner. Both provide the same validated matrix to the same deployment
workflow, preserving the existing shared execution path.

`CD / Preflight`:

- recognises manual and continuous-integration sources;
- retains the existing stale-master rejection for automated deployments;
- exposes whether deployment may proceed.

`CD / Deploy <host>` retains the existing non-fail-fast matrix execution and
Cachix deployment script.

## Testing

Add one focused standard-library test module for the publisher covering:

- successful evaluation and build;
- failed evaluation;
- failed terminal build;
- exact Nix Fast Build exit-status propagation;
- GitHub API failure not changing that exit status;
- dangling-check finalisation;
- configuration, check, and rollback-helper naming.

Workflow verification includes:

- the publisher test;
- a mocked non-empty and empty deployment dispatch probe;
- Actionlint and ShellCheck;
- repository formatting;
- targeted Nix evaluation;
- `git diff --check`.

A feature-branch CI run verifies the synthetic check names and lifecycle. The CD
dispatch remains master-only and is verified after merge by a CI run whose
deployment matrix is non-empty.

## Rollout

The old branch-protection requirement has already been removed. After the feature
is merged and `CI / Completed` has appeared successfully on master, restore
branch protection using that new required check name.

## Out of Scope

- Patching or forking Nix Fast Build for a structured build-start event.
- A visible queued state before `in_progress`.
- Synthetic checks for rollback-script helpers.
- File annotations derived from Nix logs.
- A synthetic-check reconciliation workflow.
- Changes to Manual Deployment planning or its human inputs.
