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
    # suppressedBranches = ["feat/hercules-hci-migration"]; # override HciMode
    suppressedBranches = [];
    ciSystems = [
      # CI systems intentionally evaluated by Hercules CI.
      # To disable evaluating Darwin builds, remove "aarch64-darwin" here.
      # The agent may still advertise Darwin, but HCI will not generate Darwin
      # outputs if Darwin is not present in ciSystems.
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];

    isBranchSuppressed =
      config.repo.branch
      != null
      && builtins.elem config.repo.branch suppressedBranches;

    effectiveHciMode =
      if isBranchSuppressed
      then "suppressed"
      else configuredHciMode;

    isHciSuppressed = effectiveHciMode == "suppressed";
    isHciProduction = effectiveHciMode == "production";

    isProductionBranch = config.repo.branch == "master";
    deploymentEnabled = isHciProduction && isProductionBranch;

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
  in
    assert lib.assertMsg
    (builtins.elem configuredHciMode ["suppressed" "dry" "production"])
    "configuredHciMode must be one of: suppressed, dry, production"; {
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
              text = builtins.readFile ./scripts/cachix-deploy-script.sh;
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
                export HCI_BRANCH=${escapeShellArg (
                  if config.repo.branch == null
                  then ""
                  else config.repo.branch
                )}

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
