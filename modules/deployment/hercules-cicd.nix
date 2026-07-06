{
  inputs,
  self,
  withSystem,
  ...
}: let
  flakeLib = inputs.nixpkgs.lib;

  mkDeploymentDeployable = name: cfg: let
    system = cfg.pkgs.stdenv.hostPlatform.system;
  in {
    inherit system;
    storePath = toString cfg.config.system.build.toplevel;
    rollbackScript = toString self.packages.${system}.deploy-health-rollback-script;
    deployPin = "deployed-host-${name}";
  };
in {
  flake-file.inputs.hercules-ci-effects.url = "github:hercules-ci/hercules-ci-effects";
  flake-file.inputs.hercules-ci-effects.inputs.nixpkgs.follows = "nixpkgs";
  imports = [inputs.hercules-ci-effects.flakeModule];

  flake.deploy.targets =
    flakeLib.mapAttrs mkDeploymentDeployable
    (flakeLib.filterAttrs
      (_name: cfg: cfg.config.services.cachix-agent.enable or false)
      (self.nixosConfigurations or {}));

  herculesCI = {
    config,
    lib,
    ...
  }: let
    # Master dispatches deployments; other branches only assemble a canary matrix.
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

    configurationJobPrefixes = {
      darwinConfiguration = "10";
      nixosConfiguration = "20";
    };

    nixosConfigurationNames = builtins.attrNames (self.nixosConfigurations or {});
    darwinConfigurationNames = builtins.attrNames (self.darwinConfigurations or {});

    mkConfigurationJobName = kind: name: "${configurationJobPrefixes.${kind}}-${kind}-${name}";
    requiredJobNames =
      (map (mkConfigurationJobName "nixosConfiguration") nixosConfigurationNames)
      ++ (map (mkConfigurationJobName "darwinConfiguration") darwinConfigurationNames);

    mkDeployableJob = name: cfg: let
      system = cfg.pkgs.stdenv.hostPlatform.system;
    in {
      host = name;
      inherit system;
      jobName = mkConfigurationJobName "nixosConfiguration" name;
      toplevelAttrPath = ["nixosConfigurations" name "config" "system" "build" "toplevel"];
      rollbackAttrPath = ["packages" system "deploy-health-rollback-script-${name}"];
      deployPin = "deployed-host-${name}";
    };

    mkBuiltJob = name: _cfg: {
      host = name;
      jobName = mkConfigurationJobName "nixosConfiguration" name;
      toplevelAttrPath = ["nixosConfigurations" name "config" "system" "build" "toplevel"];
      buildPin = "built-host-${name}";
    };

    builtJobs = lib.mapAttrsToList mkBuiltJob (self.nixosConfigurations or {});
    deployableJobs = lib.mapAttrsToList mkDeployableJob deployableConfigurations;

    mkDeliverablesEffect = {
      hci-effects,
      pkgs,
      mode,
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
          export HCI_DEPLOYMENT_MODE=${escapeShellArg mode}
          export HCI_DEPLOYMENT_BRANCH=${escapeShellArg config.repo.branch}
          export HCI_DEPLOYMENT_REF=${escapeShellArg config.repo.ref}
          export HCI_DEPLOYMENT_REV=${escapeShellArg config.repo.rev}
          export HCI_DEPLOYMENT_SHORT_REV=${escapeShellArg config.repo.shortRev}
          export HCI_REQUIRED_JOB_NAMES=${escapeShellArg (builtins.toJSON requiredJobNames)}
          export HCI_BUILT_JOBS=${escapeShellArg (builtins.toJSON builtJobs)}
          export HCI_DEPLOYABLE_JOBS=${escapeShellArg (builtins.toJSON deployableJobs)}
          export CACHIX_PIN_FUNCTIONS_SCRIPT="${./scripts/cachix-pin-functions.sh}"
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
    mkConfigurationJob = kind: name: cfg: let
      system = cfg.pkgs.stdenv.hostPlatform.system;
      deployable = cfg.config.services.cachix-agent.enable or false;
    in
      lib.nameValuePair (mkConfigurationJobName kind name) {
        outputs =
          {
            "${kind}s".${name}.config.system.build.toplevel = cfg.config.system.build.toplevel;
          }
          // lib.optionalAttrs deployable {
            packages.${system}."deploy-health-rollback-script-${name}" =
              self.packages.${system}.deploy-health-rollback-script;
          };
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
        # Assemble deployable paths from successful HCI config jobs and dispatch GitHub.
        "99-deliverables".outputs = withSystem "x86_64-linux" ({
          pkgs,
          hci-effects,
          ...
        }: {
          effects.production-deliverables =
            hci-effects.runIf isProductionBranch
            (mkDeliverablesEffect {
              inherit hci-effects pkgs;
              mode = "production";
              createGitHubDeployment = true;
            });

          effects.canary-deliverables =
            hci-effects.runIf (!isProductionBranch)
            (mkDeliverablesEffect {
              inherit hci-effects pkgs;
              mode = "canary";
              createGitHubDeployment = false;
            });
        });
      }
    ];
  };
}
