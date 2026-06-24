{den, ...} @ flake: {
  den.aspects.hercules.includes = [
    den.aspects.hercules.agent
    # den.aspects.hercules.namespace-darwin-broker
    den.aspects.hercules.nixbuild-linux-broker
  ];

  den.aspects.hercules.agent.nixos = {
    config,
    pkgs,
    lib,
    host,
    ...
  }: {
    # Secrets configuration
    sops.secrets = {
      cachixPushToken = {};
      cachixDeployToken = {};
      cachixPersonalToken = {};
      herculesClusterJoinToken.owner =
        config.systemd.services.hercules-ci-agent.serviceConfig.User;
    };

    # JSON binary caches configuration template for hercules-ci-agent
    sops.templates."binary-caches.json" = {
      owner = config.systemd.services.hercules-ci-agent.serviceConfig.User;
      content = builtins.toJSON {
        whitestrake = {
          kind = "CachixCache";
          authToken = config.sops.placeholder.cachixPushToken;
          publicKeys = [flake.config.caches.cachix.key];
          signingKeys = [];
        };
      };
    };

    sops.templates."hercules-secrets.json" = let
      repoCondition = {
        and = [
          {isOwner = "whitestrake";}
          {isRepo = "nixos";}
        ];
      };
      productionBranchCondition = {
        and = [
          {isOwner = "whitestrake";}
          {isRepo = "nixos";}
          {isBranch = "master";}
        ];
      };
    in {
      owner = config.systemd.services.hercules-ci-agent.serviceConfig.User;
      content = builtins.toJSON {
        "cachixPush" = {
          kind = "Secret";
          data = {token = config.sops.placeholder.cachixPushToken;};
          condition = repoCondition;
        };
        "cachixDeploy" = {
          kind = "Secret";
          data = {token = config.sops.placeholder.cachixDeployToken;};
          condition = productionBranchCondition;
        };
        "cachixPersonal" = {
          kind = "Secret";
          data = {token = config.sops.placeholder.cachixPersonalToken;};
          condition = productionBranchCondition;
        };
      };
    };

    # Enable and configure Hercules CI Agent
    services.hercules-ci-agent = {
      enable = true;
      settings = {
        clusterJoinTokenPath = config.sops.secrets.herculesClusterJoinToken.path;
        binaryCachesPath = config.sops.templates."binary-caches.json".path;
        secretsJsonPath = config.sops.templates."hercules-secrets.json".path;
      };
    };

    systemd.services.hercules-ci-agent = {
      # GHC reserves 1T of virtual address space by default on 64-bit platforms.
      # Keep worker forks from tripping Linux overcommit accounting.
      environment.GHCRTS = "-xr128G";

      # HCI effects run under the agent. If Cachix Deploy switches the same host
      # that is currently running an effect, restarting the agent can kill the
      # effect before it updates pins and reports success.
      stopIfChanged = false;
      restartIfChanged = false;
    };

    # Effects execute on the local agent after their derivation has been
    # realised. Mark native x86_64 Linux agents explicitly so effect
    # derivations cannot be treated like ordinary cross-realizable builds.
    nix.settings.extra-system-features =
      lib.optionals (host.system == "x86_64-linux") ["hci-effect-runner"];
  };

  den.aspects.hercules.nixbuild-linux-broker.nixos = {
    config,
    pkgs,
    lib,
    host,
    ...
  }: {
    sops.secrets.nixbuildBuilderKey.owner =
      config.systemd.services.hercules-ci-agent.serviceConfig.User;

    programs.ssh.extraConfig = ''
      Host eu.nixbuild.net
        PubkeyAcceptedKeyTypes ssh-ed25519
        ServerAliveInterval 60
        IPQoS throughput
        IdentityFile ${config.sops.secrets.nixbuildBuilderKey.path}
    '';

    programs.ssh.knownHosts = {
      nixbuild = {
        hostNames = ["eu.nixbuild.net"];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM";
      };
    };

    services.hercules-ci-agent.settings.remotePlatformsWithSameFeatures = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    nix = {
      distributedBuilds = true;
      settings.builders-use-substitutes = true;
      buildMachines = [
        {
          hostName = "eu.nixbuild.net";
          systems = ["x86_64-linux" "aarch64-linux"];
          maxJobs = 100;
          supportedFeatures = ["benchmark" "big-parallel"];
        }
      ];
    };
  };

  # Subaspect for inclusion on a single host ONLY to manage namespace macos instance lifecycle
  den.aspects.hercules.namespace-darwin-broker.nixos = {
    config,
    host,
    pkgs,
    lib,
    ...
  }: let
    agentUser = config.systemd.services.hercules-ci-agent.serviceConfig.User;
    enableBrokerDebug = false;

    builderHost = "namespace-mac";
    brokerName = host.name;
    runtimeKeyPath = "/run/namespace-darwin-builder/id_ed25519";

    darwin-broker-common = pkgs.writeText "darwin-broker-common.sh" (builtins.readFile ./scripts/darwin-broker-common.sh);
    darwin-guest-bootstrap = pkgs.writeText "darwin-guest-bootstrap.sh" (builtins.readFile ./scripts/darwin-guest-bootstrap.sh);

    darwin-broker-init = pkgs.writeShellApplication {
      name = "darwin-broker-init";
      runtimeInputs = with pkgs; [
        namespace-cli
        jq
        coreutils
        openssh
        systemd
      ];
      text = builtins.readFile ./scripts/darwin-broker-init.sh;
    };

    darwin-broker-ensure-instance = pkgs.writeShellApplication {
      name = "darwin-broker-ensure-instance";
      runtimeInputs = with pkgs; [
        namespace-cli
        jq
        coreutils
        openssh
      ];
      text = builtins.readFile ./scripts/darwin-broker-ensure-instance.sh;
    };

    darwin-broker-cleanup = pkgs.writeShellApplication {
      name = "darwin-broker-cleanup";
      runtimeInputs = with pkgs; [
        coreutils
        jq
        namespace-cli
      ];
      text = builtins.readFile ./scripts/darwin-broker-cleanup.sh;
    };

    darwin-broker-socket-proxy = pkgs.writeShellApplication {
      name = "darwin-broker-socket-proxy";
      runtimeInputs = with pkgs; [
        coreutils
        jq
        openssh
        namespace-cli
        darwin-broker-cleanup
        darwin-broker-ensure-instance
      ];
      text = builtins.readFile ./scripts/darwin-broker-socket-proxy.sh;
    };

    darwin-broker-reaper = pkgs.writeShellApplication {
      name = "darwin-broker-reaper";
      runtimeInputs = with pkgs; [
        namespace-cli
        jq
        coreutils
        systemd
      ];
      text = builtins.readFile ./scripts/darwin-broker-reaper.sh;
    };
  in {
    # Secrets configuration
    sops.secrets.namespaceHciToken.owner = agentUser;

    systemd.tmpfiles.rules = [
      "d /run/namespace-darwin-builder 0700 ${agentUser} ${agentUser} -"
    ];

    # SSH configuration mapping the builder host to the local socket proxy
    programs.ssh.extraConfig = ''
      Host ${builderHost}
        HostName 127.0.0.1
        Port 22022
        User root
        IdentityFile ${runtimeKeyPath}
        BatchMode yes
        IdentitiesOnly yes
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
    '';

    systemd.sockets.namespace-mac = {
      wantedBy = ["multi-user.target"];
      socketConfig = {
        ListenStream = "127.0.0.1:22022";
        Backlog = 128;
        Accept = false;
        NoDelay = true;
      };
    };

    systemd.services.namespace-mac = {
      description = "Namespace macOS SSH socket proxy";
      requires = ["namespace-darwin-builder-init.service"];
      after = ["network-online.target" "namespace-darwin-builder-init.service"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "simple";
        User = agentUser;
        Environment = [
          "NSC_TOKEN_FILE=${config.sops.secrets.namespaceHciToken.path}"
          "NAMESPACE_BUILDER_KEY_PATH=${runtimeKeyPath}"
          "NAMESPACE_DARWIN_BROKER_NAME=${brokerName}"
          "NAMESPACE_DARWIN_BROKER_COMMON=${darwin-broker-common}"
          "NAMESPACE_DARWIN_GUEST_BOOTSTRAP=${darwin-guest-bootstrap}"
          "NAMESPACE_DARWIN_RUN_DIR=/run/namespace-darwin-builder"
          "NAMESPACE_DARWIN_LEASE_TTL_SECONDS=120"
          "NAMESPACE_DARWIN_TUNNEL_PORT=22023"
          "NAMESPACE_DARWIN_BROKER_DEBUG=${lib.boolToString enableBrokerDebug}"
          "SYSTEMD_SOCKET_PROXYD=${config.systemd.package}/lib/systemd/systemd-socket-proxyd"
        ];
        ExecStart = "${darwin-broker-socket-proxy}/bin/darwin-broker-socket-proxy";
        ExecStopPost = "${darwin-broker-cleanup}/bin/darwin-broker-cleanup";
        TimeoutStartSec = "10min";
        TimeoutStopSec = "30s";
        KillMode = "mixed";
        Sockets = ["namespace-mac.socket"];
        Restart = "on-failure";
        RestartSec = "2s";
        RestartSteps = 8;
        RestartMaxDelaySec = "45s";
      };
      startLimitBurst = 12;
      startLimitIntervalSec = 120;
    };

    systemd.services.namespace-darwin-builder-init = {
      description = "Initialize Namespace macOS builder runtime state";
      after = ["network-online.target" "sops-nix.service"];
      wants = ["network-online.target"];
      before = ["namespace-mac.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = agentUser;
        Environment = [
          "NSC_TOKEN_FILE=${config.sops.secrets.namespaceHciToken.path}"
          "NAMESPACE_BUILDER_KEY_PATH=${runtimeKeyPath}"
          "NAMESPACE_DARWIN_BROKER_NAME=${brokerName}"
          "NAMESPACE_DARWIN_BROKER_COMMON=${darwin-broker-common}"
          "NAMESPACE_DARWIN_RUN_DIR=/run/namespace-darwin-builder"
          "NAMESPACE_DARWIN_BROKER_DEBUG=${lib.boolToString enableBrokerDebug}"
        ];
        ExecStart = "${darwin-broker-init}/bin/darwin-broker-init";
      };
    };

    systemd.services.namespace-darwin-builder-reaper = {
      description = "Reap idle Namespace macOS builder instances";
      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "NSC_TOKEN_FILE=${config.sops.secrets.namespaceHciToken.path}"
          "NAMESPACE_DARWIN_BROKER_NAME=${brokerName}"
          "NAMESPACE_DARWIN_BROKER_COMMON=${darwin-broker-common}"
          "NAMESPACE_DARWIN_RUN_DIR=/run/namespace-darwin-builder"
          "NAMESPACE_DARWIN_LEASE_TTL_SECONDS=120"
          "NAMESPACE_DARWIN_FAILURE_LOOKBACK_SECONDS=300"
          "NAMESPACE_DARWIN_TUNNEL_PORT=22023"
          "NAMESPACE_DARWIN_BROKER_DEBUG=${lib.boolToString enableBrokerDebug}"
        ];
        ExecStart = "${darwin-broker-reaper}/bin/darwin-broker-reaper";
        User = agentUser;
      };
    };

    systemd.timers.namespace-darwin-builder-reaper = {
      description = "Timer for Namespace macOS builder reaper";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
        AccuracySec = "5s";
      };
    };

    services.hercules-ci-agent.settings.remotePlatformsWithSameFeatures = [
      "aarch64-darwin"
    ];

    # Register the builder for distributed builds
    nix = {
      distributedBuilds = true;
      settings.builders-use-substitutes = true;
      buildMachines = [
        {
          hostName = builderHost;
          system = "aarch64-darwin";
          maxJobs = 3;
          supportedFeatures = ["big-parallel"];
          protocol = "ssh-ng";
        }
      ];
    };
  };
}
