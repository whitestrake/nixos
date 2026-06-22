{
  inputs,
  self,
  withSystem,
  ...
}: {
  flake-file.inputs.hercules-ci-effects.url = "github:hercules-ci/hercules-ci-effects";
  flake-file.inputs.hercules-ci-effects.inputs.nixpkgs.follows = "nixpkgs";
  imports = [inputs.hercules-ci-effects.flakeModule];

  herculesCI = {
    config,
    lib,
    ...
  }: let
    pinnableNixosConfigurations =
      self.nixosConfigurations or {};

    pinnableDarwinConfigurations =
      self.darwinConfigurations or {};

    pinnableConfigurations =
      pinnableNixosConfigurations // pinnableDarwinConfigurations;

    # We want to deploy to all nixosConfigurations with Cachix Agent active
    deployableNixosConfigurations =
      lib.filterAttrs
      (_name: cfg:
        (cfg.config.services.cachix-agent.enable or false)
        && !(cfg.config.wsl.enable or false))
      (self.nixosConfigurations or {});

    mkBuildItem = name: cfg: let
      system = cfg.pkgs.stdenv.hostPlatform.system;
      systemClosure = cfg.config.system.build.toplevel;
    in {
      host = name;
      inherit system;
      storePath = toString systemClosure;
      buildPin = "built-host-${name}";
    };

    mkDeployItem = name: cfg: let
      system = cfg.pkgs.stdenv.hostPlatform.system;
      systemClosure = cfg.config.system.build.toplevel;
      rollbackScript = self.packages.${system}.deploy-health-rollback-script;
    in {
      host = name;
      inherit system;
      storePath = toString systemClosure;
      deployPin = "deployed-host-${name}";
      rollbackScript = toString rollbackScript;
    };

    isProductionBranch = builtins.elem config.repo.branch ["master"];

    buildItems = lib.mapAttrsToList mkBuildItem pinnableConfigurations;
    deployItems = lib.mapAttrsToList mkDeployItem deployableNixosConfigurations;

    buildItemsJson = builtins.toJSON buildItems;
    deployItemsJson = builtins.toJSON deployItems;
  in {
    # CI systems intentionally evaluated by Hercules CI.
    # To disable evaluating Darwin builds, remove "aarch64-darwin" here.
    # The agent may still advertise Darwin, but HCI will not generate Darwin
    # outputs if Darwin is not present in ciSystems.
    ciSystems = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];

    # Temporary while we're working on this feature branch
    suppressedBranches = ["feat/hercules-hci-migration"];

    # Configure the deployment effect using Cachix Deploy
    onPush.default.outputs = withSystem "x86_64-linux" ({
      pkgs,
      hci-effects,
      ...
    }: let
      deployScript = pkgs.writeShellApplication {
        name = "cachix-deploy-script";
        runtimeInputs = with pkgs; [bash coreutils curl jq cachix];
        text = ''
          set -euo pipefail

          cache_name="''${CACHIX_CACHE_NAME:-}"
          is_production_branch="''${IS_PRODUCTION_BRANCH:-false}"
          build_items="''${BUILD_ITEMS_JSON:-[]}"
          deploy_items="''${DEPLOY_ITEMS_JSON:-[]}"

          with_retry() {
            local n=1 max=3 delay=2
            while true; do
              "$@" && break || {
                if [[ $n -lt $max ]]; then
                  ((n++))
                  echo "Command failed. Attempt $n/$max in $delay seconds:" >&2
                  sleep $delay
                  delay=$((delay * 2))
                else
                  echo "Command failed after $n attempts." >&2
                  return 1
                fi
              }
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

          pin_deployed_state() {
            local pin_name="$1"
            local store_path="$2"
            local payload

            payload="$(
              jq -n \
                --arg name "$pin_name" \
                --arg storePath "$store_path" \
                '{name: $name, storePath: $storePath, artifacts: [], keep: null}'
            )"

            with_retry curl -fsS \
              -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
              -H "Content-Type: application/json" \
              --data "$payload" \
              "https://app.cachix.org/api/v1/cache/$cache_name/pin" \
              >/dev/null
          }

          probe_cachix_agent() {
            local host="$1"
            local code

            if [ -z "''${CACHIX_PERSONAL_TOKEN:-}" ]; then
              echo "No Cachix personal token available for agent probe; skipping deploy for $host." >&2
              return 1
            fi

            code="$(
              with_retry curl -s \
                -o /dev/null \
                -w "%{http_code}" \
                -H "Authorization: Bearer $CACHIX_PERSONAL_TOKEN" \
                "https://cachix.org/api/v1/deploy/agent/$cache_name/$host" \
                || echo "000"
            )"

            if [ "$code" = "200" ]; then
              return 0
            fi

            echo "Cachix Deploy agent for '$host' is not registered/reachable (HTTP $code)." >&2
            return 1
          }

          tmpdir="$(mktemp -d)"
          cleanup() {
            rm -rf "$tmpdir"
          }
          trap cleanup EXIT

          if printf '%s\n' "$build_items" | jq -e 'type == "array" and length == 0' >/dev/null; then
            echo "No build/pin targets found. Nothing to pin or deploy."
            exit 0
          fi

          pins="$(fetch_pins)"

          echo "============================================================"
          echo "PHASE A: Built-State Pinning"
          echo "============================================================"

          phase_a_errors=0

          while read -r item; do
            host="$(jq -r '.host' <<< "$item")"
            system="$(jq -r '.system' <<< "$item")"
            store_path="$(jq -r '.storePath' <<< "$item")"
            build_pin="$(jq -r '.buildPin' <<< "$item")"

            echo "--- target: $host ---"

            if [ -z "$host" ] || [ "$host" = "null" ]; then
              echo "ERROR: malformed build item with missing host." >&2
              phase_a_errors=$((phase_a_errors + 1))
              continue
            fi

            if [ -z "$store_path" ] || [ "$store_path" = "null" ]; then
              echo "ERROR: malformed build item for $host has no storePath." >&2
              phase_a_errors=$((phase_a_errors + 1))
              continue
            fi

            previous_built="$(pin_path "$build_pin")"

            if [ "$previous_built" = "$store_path" ]; then
              echo "Built state already pinned for $host."
            else
              echo "Built state differs for $host:"
              echo "  previous: ''${previous_built:-[none]}"
              echo "  current:  $store_path"

              echo "Ensuring system closure is present in Cachix..."
              if ! with_retry cachix push "$cache_name" "$store_path"; then
                echo "Failed to push $host to cachix." >&2
                phase_a_errors=$((phase_a_errors + 1))
                continue
              fi

              echo "Pinning built state: $build_pin -> $store_path"
              if ! with_retry cachix pin "$cache_name" "$build_pin" "$store_path"; then
                echo "Failed to pin $host to cachix." >&2
                phase_a_errors=$((phase_a_errors + 1))
                continue
              fi

              pins="$(fetch_pins)" || {
                echo "Failed to fetch pins after pinning $host." >&2
                phase_a_errors=$((phase_a_errors + 1))
                continue
              }
            fi
          done < <(printf '%s\n' "$build_items" | jq -c '.[]')

          if [ "$phase_a_errors" -gt 0 ]; then
            echo "Phase A completed with $phase_a_errors errors. Skipping deploy phase." >&2
            exit 1
          fi

          if [ "$is_production_branch" != "true" ]; then
            echo "Not a production branch; deployment skipped after built-state pins."
            exit 0
          fi

          if printf '%s\n' "$deploy_items" | jq -e 'type == "array" and length == 0' >/dev/null; then
            echo "No Cachix Deploy targets found. Built-state pins are complete."
            exit 0
          fi

          echo ""
          echo "============================================================"
          echo "PHASE B: Cachix Deployment"
          echo "============================================================"

          phase_b_errors=0

          while read -r item; do
            host="$(jq -r '.host' <<< "$item")"
            system="$(jq -r '.system' <<< "$item")"
            store_path="$(jq -r '.storePath' <<< "$item")"
            deploy_pin="$(jq -r '.deployPin' <<< "$item")"
            rollback="$(jq -r '.rollbackScript' <<< "$item")"

            echo "--- deploy target: $host ---"

            if [ -z "$rollback" ] || [ "$rollback" = "null" ]; then
              echo "ERROR: deployable host $host has no rollback script. Refusing to continue." >&2
              phase_b_errors=$((phase_b_errors + 1))
              continue
            fi

            deployed="$(pin_path "$deploy_pin")"

            if [ "$deployed" = "$store_path" ]; then
              echo "Already deployed for $host:"
              echo "  $deploy_pin -> $deployed"
              continue
            fi

            echo "Deployed state differs for $host:"
            echo "  deployed: ''${deployed:-[none]}"
            echo "  current:  $store_path"

            echo "Ensuring rollback script is present in Cachix..."
            if ! with_retry cachix push "$cache_name" "$rollback"; then
              echo "Failed to push rollback script for $host." >&2
              phase_b_errors=$((phase_b_errors + 1))
              continue
            fi

            if ! probe_cachix_agent "$host"; then
              echo "Skipping deployment for $host because its Cachix Deploy agent is unavailable."
              phase_b_errors=$((phase_b_errors + 1))
              continue
            fi

            deploy_spec="$tmpdir/deploy-$host.json"

            jq -n \
              --arg agent "$host" \
              --arg path "$store_path" \
              --arg sys "$system" \
              --arg rollback "$rollback" \
              '{"agents": {($agent): $path}, "rollbackScript": {($sys): $rollback}}' \
              > "$deploy_spec"

            echo "Generated deploy spec for $host:"
            cat "$deploy_spec"

            echo "Activating Cachix Deploy for $host..."
            if ! cachix deploy activate "$deploy_spec"; then
              echo "Cachix deploy activate failed for $host." >&2
              phase_b_errors=$((phase_b_errors + 1))
              continue
            fi

            echo "Deployment succeeded for $host. Pinning deployed state:"
            echo "  $deploy_pin -> $store_path"
            if ! pin_deployed_state "$deploy_pin" "$store_path"; then
              echo "Failed to pin deployed state for $host." >&2
              phase_b_errors=$((phase_b_errors + 1))
              continue
            fi
            pins="$(fetch_pins)" || true
          done < <(printf '%s\n' "$deploy_items" | jq -c '.[]')

          if [ "$phase_b_errors" -gt 0 ]; then
            echo "Phase B completed with $phase_b_errors errors." >&2
            exit 1
          fi
        '';
      };
    in {
      # HCI builds these before running the effect.
      systems = lib.mapAttrs' (name: cfg:
        lib.nameValuePair name cfg.config.system.build.toplevel)
      pinnableConfigurations;

      rollbackScriptChecks =
        lib.mapAttrs' (
          name: cfg: let
            system = cfg.pkgs.stdenv.hostPlatform.system;
          in
            lib.nameValuePair name self.checks.${system}.validate-deploy-health-rollback-script
        )
        deployableNixosConfigurations;

      effects.cachix-state-and-deploy = hci-effects.mkEffect {
        inputs = with pkgs; [
          bash
          coreutils
          curl
          jq
          nix
          cachix
        ];

        secretsMap =
          {
            cachix = "cachix-write";
          }
          // lib.optionalAttrs isProductionBranch {
            cachixDeploy = "cachix-deploy-activate";
            cachixPersonal = "cachix-personal";
          };

        effectScript = ''
          export CACHIX_CACHE_NAME="whitestrake"
          export IS_PRODUCTION_BRANCH="${
            if isProductionBranch
            then "true"
            else "false"
          }"
          export BUILD_ITEMS_JSON=${lib.escapeShellArg buildItemsJson}
          export DEPLOY_ITEMS_JSON=${lib.escapeShellArg deployItemsJson}

          export CACHIX_AUTH_TOKEN="$(readSecretString cachix .token)"

          if [ "$IS_PRODUCTION_BRANCH" = "true" ]; then
            export CACHIX_ACTIVATE_TOKEN="$(readSecretString cachixDeploy .token)"
            export CACHIX_PERSONAL_TOKEN="$(readSecretString cachixPersonal .token)"
          else
            export CACHIX_ACTIVATE_TOKEN=""
            export CACHIX_PERSONAL_TOKEN=""
          fi

          exec ${deployScript}/bin/cachix-deploy-script
        '';
      };
    });
  };
}
