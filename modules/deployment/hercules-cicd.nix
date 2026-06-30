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
    # Master records production deliverables; other branches record canary deliverables.
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

    # Keep default hygiene cheap by excluding Darwin formatters from HCI.
    linuxFormatterSystems =
      lib.filter
      (system: !(lib.systems.elaborate system).isDarwin)
      (builtins.attrNames (self.formatter or {}));

    configurationJobPrefixes = {
      darwinConfiguration = "10";
      nixosConfiguration = "20";
    };

    nixosConfigurationNames = builtins.attrNames (self.nixosConfigurations or {});
    darwinConfigurationNames = builtins.attrNames (self.darwinConfigurations or {});
    duplicateConfigurationNames = lib.intersectLists nixosConfigurationNames darwinConfigurationNames;
    hasDuplicateConfigurationName = name: builtins.elem name duplicateConfigurationNames;

    mkConfigurationJobName = kind: name: "${configurationJobPrefixes.${kind}}-${kind}-${name}";
    mkConfigurationRecordName = kind: name:
      if hasDuplicateConfigurationName name
      then "${kind}-${name}"
      else name;
    mkConfigurationBuildPin = pinNames: kind: name:
      if hasDuplicateConfigurationName name
      then "${pinNames.host}-${kind}-${name}"
      else "${pinNames.host}-${name}";

    # Configuration records cover every configuration HCI evaluates. They drive
    # built-host-* / canary-host-* pins independently of deployability.
    mkBuildStateItem = pinNames: kind: name: cfg: let
      system = cfg.pkgs.stdenv.hostPlatform.system;
      systemClosure = cfg.config.system.build.toplevel;
    in {
      inherit kind;
      jobName = mkConfigurationJobName kind name;
      inherit system;
      storePath = toString systemClosure;
      buildPin = mkConfigurationBuildPin pinNames kind name;
    };

    # Deployable records are the subset used for Cachix Deploy state, rollback
    # pins, and GitHub Deployment payloads.
    mkDeployableStateItem = pinNames: name: cfg: let
      system = cfg.pkgs.stdenv.hostPlatform.system;
    in
      (mkBuildStateItem pinNames "nixosConfiguration" name cfg)
      // {
        rollbackScript = toString self.packages.${system}.deploy-health-rollback-script;
        rollbackPin = "${pinNames.rollback}-${name}";
        deployPin = "deployed-host-${name}";
      };

    mkConfigurationRecords = pinNames: kind: configurations:
      lib.mapAttrs' (
        name: cfg:
          lib.nameValuePair
          (mkConfigurationRecordName kind name)
          (mkBuildStateItem pinNames kind name cfg)
      )
      configurations;

    mkConfigurations = pinNames:
      (mkConfigurationRecords pinNames "nixosConfiguration" (self.nixosConfigurations or {}))
      // (mkConfigurationRecords pinNames "darwinConfiguration" (self.darwinConfigurations or {}));

    # Record all configuration deliverables plus deployable host paths. The
    # script pins every configuration, but writes only deployables as hosts in
    # the persisted deployables state.
    mkDeliverablesJson = pinNames:
      builtins.unsafeDiscardStringContext (
        builtins.toJSON {
          ref = config.repo.ref;
          branch = config.repo.branch;
          rev = config.repo.rev;
          shortRev = config.repo.shortRev;
          configurations = mkConfigurations pinNames;
          deployables = lib.mapAttrs (mkDeployableStateItem pinNames) deployableConfigurations;
        }
      );

    productionDeliverablesJson = mkDeliverablesJson {
      host = "built-host";
      rollback = "built-rollback";
    };

    canaryDeliverablesJson = mkDeliverablesJson {
      host = "canary-host";
      rollback = "canary-rollback";
    };

    mkDeliverablesEffect = {
      hci-effects,
      pkgs,
      mode,
      stateName,
      deliverablesJson,
      createGitHubDeployment,
    }:
      hci-effects.mkEffect {
        inputs = with pkgs; [bash coreutils curl jq];
        requiredSystemFeatures = [effectRunnerFeature];
        secretsMap =
          lib.genAttrs (
            ["cachixPush"]
            ++ ["githubWhitestrakeNixosStatusRead"]
            ++ lib.optional createGitHubDeployment "githubWhitestrakeNixosDeployments"
          )
          lib.id;

        effectScript = with lib; ''
          export CACHIX_CACHE_NAME="whitestrake"
          export DELIVERABLES_JSON=${escapeShellArg deliverablesJson}
          export HCI_DELIVERABLES_MODE=${escapeShellArg mode}
          export HCI_DELIVERABLES_STATE_NAME=${escapeShellArg stateName}
          export HCI_DELIVERABLES_HISTORY_LIMIT="10"
          export HCI_DELIVERABLES_CI_GATE_SCRIPT=${escapeShellArg ./scripts/hci-deployables-ci-gate.sh}
          export CACHIX_PIN_FUNCTIONS_SCRIPT=${escapeShellArg ./scripts/cachix-pin-functions.sh}
          export HCI_CREATE_GITHUB_DEPLOYMENT=${escapeShellArg (
            if createGitHubDeployment
            then "true"
            else "false"
          )}
          export CACHIX_BUILT_PIN_KEEP_REVISIONS="10"
          export CACHIX_AUTH_TOKEN="$(readSecretString cachixPush .token)"
          export GITHUB_TOKEN="$(readSecretString githubWhitestrakeNixosStatusRead .token)"
          export GITHUB_REPOSITORY="whitestrake/nixos"
          ${optionalString createGitHubDeployment ''
            export GITHUB_DEPLOYMENT_TOKEN="$(readSecretString githubWhitestrakeNixosDeployments .token)"
            export CACHIX_CREATE_GITHUB_DEPLOYMENT_SCRIPT=${./scripts/cachix-create-github-deployment.sh}
          ''}

          source ${./scripts/hci-deliverables-state-script.sh}
        '';
      };

    # Fan out each host as its own pure build job for readable GitHub status.
    mkConfigurationJob = kind: name: cfg:
      lib.nameValuePair (mkConfigurationJobName kind name) {
        outputs."${kind}s".${name}.config.system.build.toplevel = cfg.config.system.build.toplevel;
      };
  in {
    inherit ciSystems;

    # hercules-ci-effects currently auto-populates onPush.default, and the
    # documented onPush.default.enable = false option is not available in our
    # pinned version. Remove it from the returned HCI config so lexical job
    # ordering is explicit: checks/formatters first, builds next, deliverables last.
    out.onPush = lib.mkForce (builtins.removeAttrs config.onPush ["default"]);

    onPush = lib.foldl' (jobs: block: jobs // block) {} [
      {
        # Branch protection can key off this fast job: Linux checks plus Linux formatters.
        "00-checks".outputs = {
          checks.x86_64-linux = {
            inherit
              (self.checks.x86_64-linux)
              check-flake-file
              treefmt
              ;
          };
        };

        "01-formatter".outputs = {
          formatter = lib.genAttrs linuxFormatterSystems (system: self.formatter.${system});
        };
      }

      # Darwin configurations are separate jobs so macOS-only builds stay isolated.
      (lib.mapAttrs'
        (mkConfigurationJob "darwinConfiguration")
        (self.darwinConfigurations or {}))

      # NixOS configurations are separate HCI jobs for visibility and faster fanout.
      (lib.mapAttrs'
        (mkConfigurationJob "nixosConfiguration")
        (self.nixosConfigurations or {}))

      {
        # Publish built configuration pins and deployable state for GitHub.
        "99-deliverables".outputs = withSystem "x86_64-linux" ({
          pkgs,
          hci-effects,
          ...
        }: {
          packages = deployableRollbackPackages;

          effects.production-deliverables =
            hci-effects.runIf isProductionBranch
            (mkDeliverablesEffect {
              inherit hci-effects pkgs;
              mode = "production";
              stateName = "deployables.json";
              deliverablesJson = productionDeliverablesJson;
              createGitHubDeployment = true;
            });

          effects.canary-deliverables =
            hci-effects.runIf (!isProductionBranch)
            (mkDeliverablesEffect {
              inherit hci-effects pkgs;
              mode = "canary";
              stateName = "canary-deployables.json";
              deliverablesJson = canaryDeliverablesJson;
              createGitHubDeployment = false;
            });
        });
      }
    ];
  };
}
