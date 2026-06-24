{den, ...} @ flake: {
  perSystem = {pkgs, ...}: {
    checks.darwin-broker-ssh-stdin =
      pkgs.runCommand "darwin-broker-ssh-stdin" {} ''
        script=${./darwin-broker/scripts/darwin-broker-ensure-instance.sh}

        echo "Checking that stdin-fed SSH calls do not include -n..."
        if grep -n '| ssh "''${SSH_OPTS\[@\]}" "\$id@\$host"' "$script"; then
          echo "ERROR: authorized_keys install uses SSH_OPTS, whose -n option discards stdin." >&2
          exit 1
        fi

        touch "$out"
      '';
  };

  den.aspects.hercules.includes = [
    den.aspects.hercules.agent
    den.aspects.hercules.namespace-darwin-broker
    den.aspects.hercules.nixbuild-linux-broker
  ];

  den.aspects.hercules.agent.nixos = {
    config,
    pkgs,
    lib,
    host,
    ...
  }: let
    herculesCiConcurrentTasks = 2;
  in {
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
        concurrentTasks = herculesCiConcurrentTasks;
        clusterJoinTokenPath = config.sops.secrets.herculesClusterJoinToken.path;
        binaryCachesPath = config.sops.templates."binary-caches.json".path;
        secretsJsonPath = config.sops.templates."hercules-secrets.json".path;
      };
    };
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
    enableBrokerDebug = true;

    builderHost = "namespace-mac";
    brokerName = host.name;

    darwin-broker-ensure-instance = pkgs.writeShellApplication {
      name = "darwin-broker-ensure-instance";
      runtimeInputs = with pkgs; [
        namespace-cli
        jq
        coreutils
        curl
        openssh
      ];
      text = builtins.readFile ./darwin-broker/scripts/darwin-broker-ensure-instance.sh;
    };

    darwin-broker-cleanup = pkgs.writeShellApplication {
      name = "darwin-broker-cleanup";
      runtimeInputs = with pkgs; [
        coreutils
        jq
        openssh
        namespace-cli
      ];
      text = builtins.readFile ./darwin-broker/scripts/darwin-broker-cleanup.sh;
    };

    darwin-broker-socket-proxy = pkgs.writeShellApplication {
      name = "darwin-broker-socket-proxy";
      runtimeInputs = with pkgs; [
        coreutils
        jq
        openssh
        netcat
        namespace-cli
        darwin-broker-cleanup
        darwin-broker-ensure-instance
      ];
      text = builtins.readFile ./darwin-broker/scripts/darwin-broker-socket-proxy.sh;
    };

    darwin-broker-reaper = pkgs.writeShellApplication {
      name = "darwin-broker-reaper";
      runtimeInputs = with pkgs; [
        namespace-cli
        jq
        coreutils
        systemd
      ];
      text = builtins.readFile ./darwin-broker/scripts/darwin-broker-reaper.sh;
    };
  in {
    # Secrets configuration
    sops.secrets.namespaceBuilderKey.owner = agentUser;
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
        IdentityFile ${config.sops.secrets.namespaceBuilderKey.path}
        BatchMode yes
        IdentitiesOnly yes
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
    '';

    systemd.sockets.namespace-mac = {
      wantedBy = ["sockets.target"];
      socketConfig = {
        ListenStream = "127.0.0.1:22022";
        Backlog = 128;
        Accept = false;
        NoDelay = true;
      };
    };

    systemd.services.namespace-mac = {
      description = "Namespace macOS SSH socket proxy";
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "simple";
        User = agentUser;
        Environment = [
          "NSC_TOKEN_FILE=${config.sops.secrets.namespaceHciToken.path}"
          "NAMESPACE_BUILDER_KEY_PATH=${config.sops.secrets.namespaceBuilderKey.path}"
          "NAMESPACE_DARWIN_BROKER_NAME=${brokerName}"
          "NAMESPACE_DARWIN_RUN_DIR=/run/namespace-darwin-builder"
          "NAMESPACE_DARWIN_LEASE_TTL_SECONDS=120"
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
        StartLimitBurst = 12;
        StartLimitIntervalSec = "2min";
      };
    };

    systemd.services.namespace-darwin-builder-reaper = {
      description = "Reap idle Namespace macOS builder instances";
      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "NSC_TOKEN_FILE=${config.sops.secrets.namespaceHciToken.path}"
          "NAMESPACE_DARWIN_RUN_DIR=/run/namespace-darwin-builder"
          "NAMESPACE_DARWIN_LEASE_TTL_SECONDS=120"
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
          maxJobs = 1;
          supportedFeatures = ["big-parallel"];
          protocol = "ssh-ng";
        }
      ];
    };
  };
}
