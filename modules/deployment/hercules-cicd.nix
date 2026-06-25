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
    effectRunnerFeature = "hci-x86_64-effect-runner";
    ciSystems = [
      # CI systems intentionally evaluated by Hercules CI.
      # To disable evaluating Darwin builds, remove "aarch64-darwin" here.
      # The agent may still advertise Darwin, but HCI will not generate Darwin
      # outputs if Darwin is not present in ciSystems.
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];

    isProductionBranch = config.repo.branch == "master";

    pinnableNixosConfigurations = self.nixosConfigurations or {};
    pinnableDarwinConfigurations = self.darwinConfigurations or {};
    pinnableConfigurations =
      pinnableNixosConfigurations // pinnableDarwinConfigurations;

    deployableConfigurations =
      lib.filterAttrs
      (_name: cfg:
        (cfg.config.services.cachix-agent.enable or false)
        && !(cfg.config.wsl.enable or false))
      (self.nixosConfigurations or {});

    deployableSystems =
      lib.sort builtins.lessThan
      (lib.unique (lib.mapAttrsToList (_name: cfg: cfg.pkgs.stdenv.hostPlatform.system) deployableConfigurations));

    linuxFormatterSystems =
      lib.filter
      (system: lib.hasSuffix "-linux" system && builtins.hasAttr system (self.formatter or {}))
      ciSystems;

    mkToplevelOutput = cfg: {
      config.system.build.toplevel = cfg.config.system.build.toplevel;
    };

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

    mkBuildStateItem = kind: name: cfg: let
      system = cfg.pkgs.stdenv.hostPlatform.system;
      systemClosure = cfg.config.system.build.toplevel;
      isDeployable = builtins.hasAttr name deployableConfigurations;
    in
      {
        host = name;
        inherit kind system;
        storePath = toString systemClosure;
        deployable = isDeployable;
        ref = config.repo.ref;
        branch = config.repo.branch;
        rev = config.repo.rev;
        shortRev = config.repo.shortRev;
        jobName = "${kind}-${name}";
      }
      // lib.optionalAttrs isDeployable {
        rollbackScript = toString self.packages.${system}.deploy-health-rollback-script;
      };

    # Effect JSON is control-plane data only. The real build contract is
    # expressed by configurationOutputs and deploymentBuildOutputs below.
    effectBuildItemsJson = builtins.unsafeDiscardStringContext (
      builtins.toJSON (lib.mapAttrsToList mkBuildItem pinnableConfigurations)
    );
    effectDeployItemsJson = builtins.unsafeDiscardStringContext (
      builtins.toJSON (lib.mapAttrsToList mkDeployItem deployableConfigurations)
    );

    # Temporary manual-deploy bridge: the GitHub workflow fetches only this
    # deploy.json path from Cachix. Keep it contextless until that workflow no
    # longer depends on built-deploy-spec.
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

    defaultOutputs = {
      checks.x86_64-linux = {
        inherit (self.checks.x86_64-linux) check-flake-file treefmt;
      };
      formatter = lib.genAttrs linuxFormatterSystems (system: self.formatter.${system});
    };

    configurationOutputs = {
      nixosConfigurations =
        lib.mapAttrs
        (_name: cfg: mkToplevelOutput cfg)
        pinnableNixosConfigurations;
      darwinConfigurations =
        lib.mapAttrs
        (_name: cfg: mkToplevelOutput cfg)
        pinnableDarwinConfigurations;
    };

    deploymentBuildOutputs = {
      nixosConfigurations =
        lib.mapAttrs
        (_name: cfg: mkToplevelOutput cfg)
        deployableConfigurations;
      packages =
        lib.genAttrs
        deployableSystems
        (system: {
          deploy-health-rollback-script = self.packages.${system}.deploy-health-rollback-script;
        });
    };

    mkConfigurationJob = kind: name: cfg:
      lib.nameValuePair "${kind}-${name}" {
        outputs = withSystem "x86_64-linux" ({
          pkgs,
          hci-effects,
          ...
        }: let
          dependencies = with pkgs; [
            bash
            coreutils
            jq
          ];

          hostBuildJson = builtins.unsafeDiscardStringContext (
            builtins.toJSON (mkBuildStateItem kind name cfg)
          );
        in {
          "${kind}s".${name} = mkToplevelOutput cfg;

          effects.record-built-state = hci-effects.mkEffect {
            inputs = dependencies;
            requiredSystemFeatures = [effectRunnerFeature];

            effectScript = with lib; ''
              export HOST_BUILD_JSON=${escapeShellArg hostBuildJson}
              export HCI_BUILT_STATE_HISTORY_LIMIT="10"

              source ${./scripts/hci-built-state-script.sh}
            '';
          };
        });
      };

    nixosConfigurationJobs =
      lib.mapAttrs'
      (mkConfigurationJob "nixosConfiguration")
      pinnableNixosConfigurations;

    darwinConfigurationJobs =
      lib.mapAttrs'
      (mkConfigurationJob "darwinConfiguration")
      pinnableDarwinConfigurations;
  in {
    inherit ciSystems;

    onPush =
      {
        default.outputs = lib.mkForce defaultOutputs;

        configurations.outputs = withSystem "x86_64-linux" ({
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

          builtPinScript = pkgs.writeShellApplication {
            name = "cachix-built-pin-script";
            runtimeInputs = dependencies;
            text = builtins.readFile ./scripts/cachix-built-pin-script.sh;
          };
        in
          configurationOutputs
          // {
            effects.pin-built-hosts = hci-effects.runIf isProductionBranch (hci-effects.mkEffect {
              inputs = dependencies;
              requiredSystemFeatures = [effectRunnerFeature];
              secretsMap = lib.genAttrs ["cachixPush"] lib.id;

              effectScript = with lib; ''
                export CACHIX_CACHE_NAME="whitestrake"
                export BUILD_ITEMS_JSON=${escapeShellArg effectBuildItemsJson}
                export CACHIX_AUTH_TOKEN="$(readSecretString cachixPush .token)"

                exec ${builtPinScript}/bin/cachix-built-pin-script
              '';
            });
          });

        deployment.outputs = withSystem "x86_64-linux" ({
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
        in
          deploymentBuildOutputs
          // {
            inherit deploySpec;

            effects.pin-and-deploy = hci-effects.runIf isProductionBranch (hci-effects.mkEffect {
              inputs = dependencies;
              requiredSystemFeatures = [effectRunnerFeature];
              secretsMap = lib.genAttrs ["cachixPush" "cachixDeploy" "cachixPersonal"] lib.id;
              __hci_effect_mounts = builtins.toJSON {
                "/effect-locks" = "deploymentLocks";
              };

              effectScript = with lib; ''
                lock="/effect-locks/pin-and-deploy.lock"
                mkdir -p "$(dirname "$lock")"
                printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" > "$lock"
                cleanup_lock() {
                  rm -f "$lock"
                }
                trap cleanup_lock EXIT INT TERM

                export CACHIX_CACHE_NAME="whitestrake"
                export DEPLOY_ITEMS_JSON=${escapeShellArg effectDeployItemsJson}
                export DEPLOY_SPEC_PATH=${escapeShellArg "${deploySpec}"}
                export DEPLOY_SPEC_PIN="built-deploy-spec"

                export CACHIX_AUTH_TOKEN="$(readSecretString cachixPush .token)"
                export CACHIX_ACTIVATE_TOKEN="$(readSecretString cachixDeploy .token)"
                export CACHIX_PERSONAL_TOKEN="$(readSecretString cachixPersonal .token)"

                ${deployScript}/bin/cachix-deploy-script
              '';
            });
          });
      }
      // nixosConfigurationJobs
      // darwinConfigurationJobs;
  };
}
