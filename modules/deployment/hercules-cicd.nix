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
    # Only master effects mutate Cachix pins or HCI deployment state.
    isProductionBranch = config.repo.branch == "master";

    # Effects must execute on native x86_64 Linux agents, even if builds fan out.
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

    # Deployable hosts are the NixOS configurations managed by Cachix Deploy.
    deployableConfigurations =
      lib.filterAttrs
      (_name: cfg: cfg.config.services.cachix-agent.enable or false)
      (self.nixosConfigurations or {});

    # Keep default hygiene cheap by excluding Darwin formatters from HCI.
    linuxFormatterSystems =
      lib.filter
      (system: !(lib.systems.elaborate system).isDarwin)
      (builtins.attrNames (self.formatter or {}));

    # Build per-host deployable proofs that GitHub downloads from HCI state
    # later to construct and issue Cachix Deploy specs for exact store paths.
    mkDeployableStateItem = name: cfg: let
      system = cfg.pkgs.stdenv.hostPlatform.system;
      systemClosure = cfg.config.system.build.toplevel;
    in {
      kind = "nixosConfiguration";
      jobName = "nixosConfiguration-${name}";
      inherit system;
      storePath = toString systemClosure;
      buildPin = "built-host-${name}";
      rollbackScript = toString self.packages.${system}.deploy-health-rollback-script;
      rollbackPin = "built-rollback-${name}";
      deployPin = "deployed-host-${name}";
    };

    # Record deployable hosts plus exact paths so GitHub can later build the
    # Cachix Deploy matrix without re-evaluating the flake.
    deployablesStateJson = builtins.unsafeDiscardStringContext (
      builtins.toJSON {
        ref = config.repo.ref;
        branch = config.repo.branch;
        rev = config.repo.rev;
        shortRev = config.repo.shortRev;
        deployables = lib.sort builtins.lessThan (builtins.attrNames deployableConfigurations);
        hosts = lib.mapAttrs mkDeployableStateItem deployableConfigurations;
      }
    );

    deployableRollbackPackages =
      lib.foldl'
      (
        packages: name: let
          system = deployableConfigurations.${name}.pkgs.stdenv.hostPlatform.system;
        in
          packages
          // {
            ${system} =
              (packages.${system} or {})
              // {
                "deploy-health-rollback-script-${name}" =
                  self.packages.${system}.deploy-health-rollback-script;
              };
          }
      )
      {}
      (builtins.attrNames deployableConfigurations);

    # Fan out each host as its own pure build job for readable GitHub status.
    mkConfigurationJob = kind: name: cfg:
      lib.nameValuePair "${kind}-${name}" {
        outputs."${kind}s".${name}.config.system.build.toplevel = cfg.config.system.build.toplevel;
      };
  in {
    inherit ciSystems;

    onPush = lib.foldl' (jobs: block: jobs // block) {} [
      {
        # Branch protection can key off this fast job: Linux checks plus Linux formatters.
        default.outputs = lib.mkForce {
          checks.x86_64-linux = {
            inherit (self.checks.x86_64-linux) check-flake-file treefmt;
          };
          formatter = lib.genAttrs linuxFormatterSystems (system: self.formatter.${system});
        };

        # Build deployable host outputs and publish their pin/deploy state for GitHub.
        deployables.outputs = withSystem "x86_64-linux" ({
          pkgs,
          hci-effects,
          ...
        }: {
          nixosConfigurations =
            lib.mapAttrs
            (_name: cfg: {
              config.system.build.toplevel = cfg.config.system.build.toplevel;
            })
            deployableConfigurations;

          packages = deployableRollbackPackages;

          effects.record-deployables = hci-effects.runIf isProductionBranch (hci-effects.mkEffect {
            inputs = with pkgs; [bash coreutils curl jq];
            requiredSystemFeatures = [effectRunnerFeature];
            secretsMap = lib.genAttrs ["cachixPush"] lib.id;

            effectScript = with lib; ''
              export CACHIX_CACHE_NAME="whitestrake"
              export DEPLOYABLES_JSON=${escapeShellArg deployablesStateJson}
              export HCI_DEPLOYABLES_HISTORY_LIMIT="10"
              export CACHIX_BUILT_PIN_KEEP_REVISIONS="10"
              export CACHIX_AUTH_TOKEN="$(readSecretString cachixPush .token)"

              source ${./scripts/hci-deployables-state-script.sh}
            '';
          });
        });
      }

      # NixOS configurations are separate HCI jobs for visibility and faster fanout.
      (lib.mapAttrs'
        (mkConfigurationJob "nixosConfiguration")
        (self.nixosConfigurations or {}))

      # Darwin configurations are separate jobs so the macOS builder wakes only for them.
      (lib.mapAttrs'
        (mkConfigurationJob "darwinConfiguration")
        (self.darwinConfigurations or {}))
    ];
  };
}
