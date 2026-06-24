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
    dryRun = false;
    ciSystems = [
      # CI systems intentionally evaluated by Hercules CI.
      # To disable evaluating Darwin builds, remove "aarch64-darwin" here.
      # The agent may still advertise Darwin, but HCI will not generate Darwin
      # outputs if Darwin is not present in ciSystems.
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];

    hciMode =
      if dryRun
      then "dry"
      else "production";

    isProductionBranch = config.repo.branch == "master";
    deploymentEnabled = !dryRun && isProductionBranch;

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

    deployableSystems =
      lib.sort builtins.lessThan
      (lib.unique (lib.mapAttrsToList (_name: cfg: cfg.pkgs.stdenv.hostPlatform.system) deployableConfigurations));

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

    # Effect payloads are control data only. HCI's default flake output
    # traversal supplies the host toplevel build outputs.
    effectBuildItemsJson = builtins.unsafeDiscardStringContext (
      builtins.toJSON (lib.mapAttrsToList mkBuildItem pinnableConfigurations)
    );
    effectDeployItemsJson = builtins.unsafeDiscardStringContext (
      builtins.toJSON (lib.mapAttrsToList mkDeployItem deployableConfigurations)
    );
    effectDeploySpecJson = builtins.unsafeDiscardStringContext (
      builtins.toJSON {
        agents =
          lib.mapAttrs
          (_name: cfg: toString cfg.config.system.build.toplevel)
          deployableConfigurations;
        rollbackScript =
          lib.listToAttrs
          (builtins.map (system: {
              name = system;
              value = toString self.packages.${system}.deploy-health-rollback-script;
            })
            deployableSystems);
      }
    );
  in {
    inherit ciSystems;

    # Configure the deployment effect using Cachix Deploy
    onPush = {
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

        deploySpec = pkgs.writeTextDir "deploy.json" effectDeploySpecJson;
      in {
        checks = lib.mkForce {
          inherit (self.checks) x86_64-linux aarch64-linux;
        };

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
            export HCI_MODE=${escapeShellArg hciMode}
            export DEPLOYMENT_ENABLED="${boolToString deploymentEnabled}"
            export HCI_BRANCH=${escapeShellArg (
              if config.repo.branch == null
              then ""
              else config.repo.branch
            )}

            export CACHIX_CACHE_NAME="whitestrake"
            export BUILD_ITEMS_JSON=${escapeShellArg effectBuildItemsJson}
            export DEPLOY_ITEMS_JSON=${escapeShellArg effectDeployItemsJson}
            export DEPLOY_SPEC_PATH=${escapeShellArg "${deploySpec}"}
            export DEPLOY_SPEC_PIN="built-deploy-spec"

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
