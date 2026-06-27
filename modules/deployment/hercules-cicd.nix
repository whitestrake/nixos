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
    # Master records production deployables; other branches record canary deployables.
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

    mkConfigurationJobName = kind: name: "${configurationJobPrefixes.${kind}}-${kind}-${name}";

    # Build per-host deployable records used for Cachix pins, HCI state, and
    # GitHub Deployment payloads with exact store paths.
    mkDeployableStateItem = pinNames: name: cfg: let
      kind = "nixosConfiguration";
      system = cfg.pkgs.stdenv.hostPlatform.system;
      systemClosure = cfg.config.system.build.toplevel;
    in {
      inherit kind;
      jobName = mkConfigurationJobName kind name;
      inherit system;
      storePath = toString systemClosure;
      buildPin = "${pinNames.host}-${name}";
      rollbackScript = toString self.packages.${system}.deploy-health-rollback-script;
      rollbackPin = "${pinNames.rollback}-${name}";
      deployPin = "deployed-host-${name}";
    };

    # Record deployable hosts plus exact paths so the HCI effect can publish
    # deployment payloads, while manual deploys can still read HCI state.
    # The hosts object is the source of truth; scripts derive host lists from it.
    mkDeployablesStateJson = pinNames:
      builtins.unsafeDiscardStringContext (
        builtins.toJSON {
          ref = config.repo.ref;
          branch = config.repo.branch;
          rev = config.repo.rev;
          shortRev = config.repo.shortRev;
          hosts = lib.mapAttrs (mkDeployableStateItem pinNames) deployableConfigurations;
        }
      );

    productionDeployablesStateJson = mkDeployablesStateJson {
      host = "built-host";
      rollback = "built-rollback";
    };

    canaryDeployablesStateJson = mkDeployablesStateJson {
      host = "canary-host";
      rollback = "canary-rollback";
    };

    mkRecordDeployablesEffect = {
      hci-effects,
      pkgs,
      mode,
      stateName,
      deployablesJson,
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
          export DEPLOYABLES_JSON=${escapeShellArg deployablesJson}
          export HCI_DEPLOYABLES_MODE=${escapeShellArg mode}
          export HCI_DEPLOYABLES_STATE_NAME=${escapeShellArg stateName}
          export HCI_DEPLOYABLES_HISTORY_LIMIT="10"
          export HCI_DEPLOYABLES_CI_GATE_SCRIPT=${escapeShellArg ./scripts/hci-deployables-ci-gate.sh}
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

          source ${./scripts/hci-deployables-state-script.sh}
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
    # ordering is explicit: checks/formatters first, builds next, deployment last.
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
        # Build rollback aliases and publish deployable pin/state for GitHub.
        "99-deployment".outputs = withSystem "x86_64-linux" ({
          pkgs,
          hci-effects,
          ...
        }: {
          packages = deployableRollbackPackages;

          effects.record-deployables =
            hci-effects.runIf isProductionBranch
            (mkRecordDeployablesEffect {
              inherit hci-effects pkgs;
              mode = "production";
              stateName = "deployables.json";
              deployablesJson = productionDeployablesStateJson;
              createGitHubDeployment = true;
            });

          effects.record-canary-deployables =
            hci-effects.runIf (!isProductionBranch)
            (mkRecordDeployablesEffect {
              inherit hci-effects pkgs;
              mode = "canary";
              stateName = "canary-deployables.json";
              deployablesJson = canaryDeployablesStateJson;
              createGitHubDeployment = false;
            });
        });
      }
    ];
  };
}
