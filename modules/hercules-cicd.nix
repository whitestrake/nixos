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
    # Configuration
    configuredHciMode = "dry"; # "suppressed" | "dry" | "production"
    suppressedBranches = ["feat/hercules-hci-migration"]; # override HciMode
    ciSystems = [
      # CI systems intentionally evaluated by Hercules CI.
      # To disable evaluating Darwin builds, remove "aarch64-darwin" here.
      # The agent may still advertise Darwin, but HCI will not generate Darwin
      # outputs if Darwin is not present in ciSystems.
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];

    isHciSuppressed =
      config.repo.branch
      != null
      && builtins.elem config.repo.branch suppressedBranches;

    effectiveHciMode =
      if isHciSuppressed
      then "suppressed"
      else configuredHciMode;

    isProductionBranch = config.repo.branch == "master";
    deploymentEnabled = (effectiveHciMode == "production") && isProductionBranch;

    # We want to build all nixosConfigurations and darwinConfigurations
    pinnableNixosConfigurations = self.nixosConfigurations or {};
    pinnableDarwinConfigurations = self.darwinConfigurations or {};
    pinnableConfigurations =
      pinnableNixosConfigurations // pinnableDarwinConfigurations;

    # We want to deploy to all nixosConfigurations with Cachix Agent active
    deployableConfigurations =
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

    buildItems = lib.mapAttrsToList mkBuildItem pinnableConfigurations;
    deployItems = lib.mapAttrsToList mkDeployItem deployableConfigurations;

    buildItemsJson = builtins.toJSON buildItems;
    deployItemsJson = builtins.toJSON deployItems;
  in {
    inherit ciSystems;

    # Configure the deployment effect using Cachix Deploy
    onPush =
      if isHciSuppressed
      then lib.mkForce {}
      else {
        default.outputs = withSystem "x86_64-linux" ({
          pkgs,
          hci-effects,
          ...
        }: let
          dependencies = with pkgs; [
            bash
            coreutils
            curl
            jq
            nix
            cachix
          ];

          deployScript = pkgs.writeShellApplication {
            name = "cachix-deploy-script";
            runtimeInputs = dependencies;
            text = ''
              set -euo pipefail

              cache_name="''${CACHIX_CACHE_NAME:-}"
              hci_mode="''${HCI_MODE:-dry}"
              deployment_enabled="''${DEPLOYMENT_ENABLED:-false}"
              build_items="''${BUILD_ITEMS_JSON:-[]}"
              deploy_items="''${DEPLOY_ITEMS_JSON:-[]}"

              is_dry_run() {
                [ "$hci_mode" = "dry" ]
              }

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

              deploy_one() {
                local item="$1"
                local host system store_path deploy_pin rollback deployed deploy_spec

                host="$(jq -r '.host' <<< "$item")"
                system="$(jq -r '.system' <<< "$item")"
                store_path="$(jq -r '.storePath' <<< "$item")"
                deploy_pin="$(jq -r '.deployPin' <<< "$item")"
                rollback="$(jq -r '.rollbackScript' <<< "$item")"

                # deploy item validation here
                if [ -z "$host" ] || [ "$host" = "null" ]; then
                  echo "ERROR: malformed deploy item with missing host: $item" >&2
                  return 1
                fi

                if [ -z "$store_path" ] || [ "$store_path" = "null" ]; then
                  echo "ERROR: malformed deploy item for $host has no storePath." >&2
                  return 1
                fi

                if [ -z "$deploy_pin" ] || [ "$deploy_pin" = "null" ]; then
                  echo "ERROR: malformed deploy item for $host has no deployPin." >&2
                  return 1
                fi

                if [ -z "$rollback" ] || [ "$rollback" = "null" ]; then
                  echo "ERROR: deployable host $host has no rollback script. Refusing to continue." >&2
                  return 1
                fi

                deployed="$(pin_path "$deploy_pin")"

                if [ "$deployed" = "$store_path" ]; then
                  echo "Already deployed for $host:"
                  echo "  $deploy_pin -> $deployed"
                  return 0
                fi

                echo "Deployed state differs for $host:"
                echo "  deployed: ''${deployed:-[none]}"
                echo "  current:  $store_path"

                deploy_spec="$tmpdir/deploy-$host.json"

                jq -n \
                  --arg agent "$host" \
                  --arg path "$store_path" \
                  --arg sys "$system" \
                  --arg rollback "$rollback" \
                  '{"agents": {($agent): $path}, "rollbackScript": {($sys): $rollback}}' \
                  > "$deploy_spec"

                if is_dry_run; then
                  echo "[dry-run] would push rollback script for $host: $rollback"
                  echo "[dry-run] would probe Cachix Deploy agent for $host: skipped in dry mode"
                  echo "[dry-run] would activate Cachix Deploy for $host with spec:"
                  cat "$deploy_spec"
                  echo "[dry-run] would pin deployed state: $deploy_pin -> $store_path"
                  return 0
                fi

                echo "Ensuring rollback script is present in Cachix..."
                if ! with_retry cachix push "$cache_name" "$rollback"; then
                  echo "Failed to push rollback script for $host to Cachix." >&2
                  return 1
                fi

                if ! probe_cachix_agent "$host"; then
                  echo "Deployment failed for $host because its Cachix Deploy agent is unavailable." >&2
                  return 1
                fi

                echo "Generated deploy spec for $host:"
                cat "$deploy_spec"

                echo "Activating Cachix Deploy for $host..."
                if ! cachix deploy activate "$deploy_spec"; then
                  echo "Cachix deploy activate failed for $host." >&2
                  return 1
                fi

                echo "Deployment succeeded for $host. Pinning deployed state:"
                echo "  $deploy_pin -> $store_path"
                if ! pin_deployed_state "$deploy_pin" "$store_path"; then
                  echo "Failed to pin deployed state for $host." >&2
                  return 1
                fi
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

                  if is_dry_run; then
                    echo "[dry-run] would push system closure for $host: $store_path"
                    echo "[dry-run] would pin built state: $build_pin -> $store_path"
                  else
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
                fi
              done < <(printf '%s\n' "$build_items" | jq -c '.[]')

              if [ "$phase_a_errors" -gt 0 ]; then
                echo "Phase A completed with $phase_a_errors errors. Skipping deploy phase." >&2
                exit 1
              fi

              if [ "$deployment_enabled" != "true" ]; then
                if is_dry_run; then
                  echo "HCI dry mode: deployment mutations disabled. Evaluating deploy candidates for logging only."
                else
                  echo "Deployment disabled for this branch/mode; deployment skipped after built-state pins."
                  exit 0
                fi
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
              declare -A deploy_pids=()
              declare -A deploy_logs=()

              while IFS= read -r item; do
                host="$(jq -r '.host // "unknown"' <<< "$item")"
                log="$tmpdir/deploy-$host.log"
                deploy_logs["$host"]="$log"

                (
                  deploy_one "$item"
                ) >"$log" 2>&1 &

                deploy_pids["$host"]=$!
              done < <(printf '%s\n' "$deploy_items" | jq -c '.[]')

              for host in "''${!deploy_pids[@]}"; do
                pid="''${deploy_pids[$host]}"
                log="''${deploy_logs[$host]}"

                if wait "$pid"; then
                  echo "Deployment job succeeded for $host."
                else
                  rc="$?"
                  echo "Deployment job failed for $host with exit code $rc." >&2
                  phase_b_errors=$((phase_b_errors + 1))
                fi

                echo "----- deploy log: $host -----"
                cat "$log"
              done

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
            deployableConfigurations;

          effects.pin-and-deploy = hci-effects.mkEffect {
            inputs = dependencies;

            secretsMap =
              lib.genAttrs (
                ["cachixPush"]
                ++ lib.optionals deploymentEnabled [
                  "cachixDeploy"
                  "cachixPersonal"
                ]
              )
              lib.id;

            effectScript = with lib; ''
              export HCI_MODE=${escapeShellArg effectiveHciMode}
              export DEPLOYMENT_ENABLED="${boolToString deploymentEnabled}"

              export CACHIX_CACHE_NAME="whitestrake"
              export BUILD_ITEMS_JSON=${escapeShellArg buildItemsJson}
              export DEPLOY_ITEMS_JSON=${escapeShellArg deployItemsJson}

              export CACHIX_AUTH_TOKEN="$(readSecretString cachixPush .token)"

              if [ "$DEPLOYMENT_ENABLED" = "true" ]; then
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
  };
}
