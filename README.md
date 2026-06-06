# Whitestrake's NixOS Configuration

A dendritic Nix flake for managing NixOS, nix-darwin, WSL, Home Manager, packages, secrets, and deployment behavior from a centralized declarative source of truth.

It follows the dendritic Nix pattern[2] through the Den framework[4], and is meant to be explored through the flake structure rather than through a hand-maintained inventory. The evaluated flake remains authoritative for the current set of hosts, aspects, packages, checks, and deployment outputs.

## Configuration Model

The repository is organized around Den/dendritic composition rather than a flat collection of host files. Host and user metadata define the topology, while reusable aspects attach system, service, hardware, monitoring, deployment, and Home Manager behavior where applicable.

`flake.nix` is the root entry point, but `modules/den.nix` is the de-facto entry point into the configuration model after that. It defines the Den topology that the rest of the flake flows through: hosts, users, context, and the way aspects are composed into concrete outputs.

Aspects describe capabilities, roles, and reusable behavior. Host-specific directories primarily compose those capabilities and hold local details such as hardware profiles, disk layout, or machine-specific overrides. This keeps most changes reviewable as shared configuration rather than isolated host mutations.

Prose lists in this README should not be treated as authoritative inventories. If the question is “what exists right now?”, inspect or evaluate the flake.

## Repository Structure

The following paths are the main landmarks for navigating the repository:

- **`flake.nix`**: The flake root. Defines inputs and outputs, wires in [flake-parts](https://github.com/hercules-ci/flake-parts), and loads the module tree.
- **`modules/den.nix`**: The main Den topology definition. This is the most important file to read after `flake.nix` when trying to understand how the repository composes hosts, users, and aspects.
- **`modules/`**: The primary module tree for flake, Den, host, deployment, package, and reusable configuration logic.
- **`modules/aspects/`**: The main reusable composition layer. Aspects describe thematic or capability-based configuration such as base system behavior, services, monitoring, deployment support, hardware roles, or host classes.
- **`modules/aspects/hosts/`**: Host-specific composition. Each host directory composes reusable aspects and carries local machine details.
- **Host-private files**: Files such as `_hardware.nix` or `_disko.nix`, where present, are local to a host and imported explicitly. They are not reusable aspects.
- **`pkgs/`**: Custom packages, package definitions, and overrides that are not provided directly by Nixpkgs in the required form.
- **`.github/workflows/`**: GitHub Actions workflows for validation, builds, deployment planning, dependency updates, and flake maintenance.
- **`secrets/`**: [SOPS](https://github.com/getsops/sops)-encrypted secret material governed by `.sops.yaml`.

## Maintenance Model

The repository is maintained with a pragmatic branching model based on risk and review value.

- **Trivial changes**: Small administrative or low-risk changes may be committed directly to `master` where appropriate.
- **Lightly experimental changes**: A feature branch may be used for local or CI validation before merging back to `master`.
- **Large or risky changes**: A feature branch and pull request should be used to document, review, iterate, and preserve context before merge.
- **Canary deployments**: Significant changes can be tested from a branch by manually dispatching deployment workflows against a designated canary host before broader rollout.

The goal is to match the amount of review and deployment caution to the operational risk of the change.

## Linting and Diagnostics

The repository uses formatting and diagnostic tools to keep routine issues out of review:

- **Nix files**: [alejandra](https://github.com/kamadorueda/alejandra) is used for formatting, and [nil](https://github.com/oxalica/nil) provides Nix language diagnostics.
- **GitHub workflows**: [actionlint](https://github.com/rhysd/actionlint) validates workflow syntax, and [yamlfmt](https://github.com/google/yamlfmt) formats YAML files.

These tools support consistency and fast feedback. They are not a substitute for evaluating the flake, checking generated outputs, or considering deployment safety.

## CI/CD Goals

CI is structured to separate evaluation, validation, building, deployment planning, and host-side safety checks.

- **Evaluation and structural validation**: Broad flake and schema checks catch broken composition early without forcing unnecessary full-system realization on every path.
- **Targeted builds**: Host, package, and check builds are kept as focused as practical. [Cachix](https://www.cachix.org/) is used to avoid repeated work and to make successful artifacts available to later jobs and hosts.
- **Deployment planning**: Deployment jobs derive their target matrix dynamically from changed host outputs and deploy-agent availability.
- **Primary deployment path**: [Cachix Deploy](https://docs.cachix.org/deploy/) is the normal automated pull-based deployment mechanism.
- **Fallback deployment path**: [deploy-rs](https://github.com/serokell/deploy-rs) remains available for manual deployment, comparison, or fallback use where the Cachix Deploy path is not appropriate.
- **Dependency maintenance**: Automated workflows update flake inputs, custom packages, GitHub Actions, and other non-Nix dependencies.

A successful CI build proves that the relevant configuration evaluates and builds. It does not, by itself, prove that an activated host remains reachable or healthy after deployment. That boundary is handled separately by deployment gating and host-side checks.

## Secrets Management

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) and integrated through [sops-nix](https://github.com/Mic92/sops-nix). Access policy is defined by `age` recipients in `.sops.yaml`.

Shared encrypted payloads live under `secrets/`. Host access is controlled by adding the appropriate recipient keys to the SOPS policy and updating encrypted files with the expected key set.

When introducing a new host, the bootstrap flow pre-creates the host SSH key locally. The corresponding `age` recipient is derived from that host key and added to `.sops.yaml` before the machine goes live. This allows `sops-nix` on the target host to derive the expected identity from the system SSH host key and decrypt the secrets required for its role.

## Deployment Safety, Rollbacks, and Health Checks

The repository distinguishes between build-time validation, deploy-time gating, and host-side post-activation health checks.

Build-time validation catches evaluation errors, failed builds, broken checks, and invalid generated outputs. Deploy-time gating decides which hosts should receive a deployment and whether the relevant deploy agent is available. Host-side health checks validate that the activated system is actually usable after switching generations.

Cachix Deploy hosts use a post-activation health and rollback script defined in the deployment modules. After activation, the host validates critical local services and access paths. If required checks fail, the deployment is treated as failed and the host can roll back to the previous generation.

Health checks should be host-aware. Different machines expose different critical services, so checks should be attached through reusable capabilities, aspects, or host metadata rather than hardcoded hostname exceptions. Remote access paths such as SSH and Tailscale should be treated as lockout-critical where applicable.

## Bootstrapping a New Host

New hosts are introduced from a local feature branch and provisioned with [nixos-anywhere](https://github.com/nix-community/nixos-anywhere).

The bootstrap process pre-creates the host SSH key, derives the corresponding SOPS `age` recipient, updates the secrets policy, provisions the target machine, and adds the resulting host composition and hardware details to the flake.

By the time the host branch is merged, the machine should already exist, have its expected network access paths, and be able to decrypt the secrets required for its role. Host inclusion should be treated as an operational change, not only a flake edit.

## Exploring the Flake

The repository is easiest to understand by following the composition model rather than by looking for a single exhaustive configuration file.

`flake.nix` shows the top-level inputs, module loading, and generated outputs. `modules/den.nix` then shows the Den topology that gives those outputs their shape.

Host configuration flows from `modules/aspects/hosts/<hostname>` into the aspects it includes. Reusable aspects generally explain shared behavior better than host-specific files, while host-private files such as hardware profiles and disk layouts provide the local details needed by an individual machine.

The CI workflows are best read in terms of which flake outputs they evaluate, build, cache, or deploy. Deployment and health-check modules are worth treating as operational safety boundaries rather than ordinary service configuration.

README prose is intentionally only a map of the repository shape. For current state, evaluate or inspect the flake itself.