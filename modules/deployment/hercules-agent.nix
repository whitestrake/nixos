{den, ...} @ flake: {
  den.aspects.hercules.includes = [
    den.aspects.hercules.agent
    den.aspects.hercules.nixbuild-linux-broker
    # den.aspects.hercules.namespace-darwin-broker
  ];

  den.aspects.hercules.agent.nixos = {
    config,
    pkgs,
    lib,
    host,
    ...
  }: let
    agentExecStart = config.systemd.services.hercules-ci-agent.serviceConfig.ExecStart;
    agentConfigPath =
      lib.head (lib.splitString " " (lib.last (lib.splitString "--config " agentExecStart)));
    agentBin = "${config.services.hercules-ci-agent.package}/libexec/hercules-ci-agent";
  in {
    # Secrets configuration
    sops.secrets = {
      cachixPushToken = {};
      cachixDeployToken = {};
      cachixPersonalToken = {};
      githubWhitestrakeNixosDeploymentsToken = {};
      githubWhitestrakeNixosStatusReadToken = {};
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
        "githubWhitestrakeNixosDeployments" = {
          kind = "Secret";
          data = {token = config.sops.placeholder.githubWhitestrakeNixosDeploymentsToken;};
          condition = productionBranchCondition;
        };
        "githubWhitestrakeNixosStatusRead" = {
          kind = "Secret";
          data = {token = config.sops.placeholder.githubWhitestrakeNixosStatusReadToken;};
          condition = repoCondition;
        };
      };
    };

    # Enable and configure Hercules CI Agent
    services.hercules-ci-agent = {
      enable = true;
      tomlFile = lib.mkForce (pkgs.writeText "hercules-ci-agent.json" (builtins.toJSON config.services.hercules-ci-agent.settings));
      settings = {
        clusterJoinTokenPath = config.sops.secrets.herculesClusterJoinToken.path;
        binaryCachesPath = config.sops.templates."binary-caches.json".path;
        secretsJsonPath = config.sops.templates."hercules-secrets.json".path;
        nixVerbosity = "Notice";
      };
    };
    den.deploy.health.requiredSystemdUnits = ["hercules-ci-agent.service"];

    systemd.services.hercules-ci-agent = {
      # GHC reserves 1T of virtual address space by default on 64-bit platforms.
      # Keep worker forks from tripping Linux overcommit accounting.
      environment.GHCRTS = "-xr128G";

      # Upstream does not set these. Keep switches from killing active HCI
      # builds/effects; the config-restarter below handles stale agent configs.
      stopIfChanged = false;
      restartIfChanged = false;
    };

    # Because the main unit is not restarted by activation, this oneshot checks
    # whether the running agent still matches the current config and binary. If
    # not, it delegates to upstream restarter only while no HCI worker is active.
    systemd.services.hercules-ci-agent-config-restarter = {
      description = "Trigger Hercules CI Agent restarter when the running agent is stale";
      wantedBy = ["multi-user.target"];
      after = ["hercules-ci-agent.service"];
      restartTriggers = [agentExecStart];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        retry_timer="hercules-ci-agent-config-restarter-retry.timer"

        stop_retry_timer() {
          ${pkgs.systemd}/bin/systemctl stop "$retry_timer" >/dev/null 2>&1 || true
        }

        agent_has_workers() {
          local control_group cgroup_procs pid cmdline

          control_group="$(${pkgs.systemd}/bin/systemctl show -p ControlGroup --value hercules-ci-agent.service 2>/dev/null || true)"
          if [ -z "$control_group" ]; then
            echo "hercules-ci-agent-config-restarter: could not determine agent control group."
            return 2
          fi

          cgroup_procs="/sys/fs/cgroup$control_group/cgroup.procs"
          if [ ! -r "$cgroup_procs" ]; then
            echo "hercules-ci-agent-config-restarter: cannot inspect $cgroup_procs."
            return 2
          fi

          while IFS= read -r pid; do
            if [ -z "$pid" ] || [ "$pid" = "$main_pid" ] || [ ! -r "/proc/$pid/cmdline" ]; then
              continue
            fi

            cmdline="$(${pkgs.coreutils}/bin/tr '\0' ' ' < "/proc/$pid/cmdline" || true)"
            case "$cmdline" in
              *hercules-ci-agent-worker*)
                echo "hercules-ci-agent-config-restarter: active worker pid $pid: $cmdline"
                return 0
                ;;
            esac
          done < "$cgroup_procs"

          return 1
        }

        restart_or_defer() {
          local reason="$1" worker_status

          echo "hercules-ci-agent-config-restarter: $reason"
          if agent_has_workers; then
            echo "hercules-ci-agent-config-restarter: agent is busy; retrying stale restart check in 2 minutes."
            ${pkgs.systemd}/bin/systemctl restart "$retry_timer"
            exit 0
          else
            worker_status=$?
          fi

          if [ "$worker_status" = "2" ]; then
            echo "hercules-ci-agent-config-restarter: worker state unknown; restarting rather than leaving stale agent running."
          else
            stop_retry_timer
          fi

          ${pkgs.systemd}/bin/systemctl start hercules-ci-agent-restarter.service
          exit 0
        }

        main_pid="$(${pkgs.systemd}/bin/systemctl show -p MainPID --value hercules-ci-agent.service 2>/dev/null || true)"
        if [ -z "$main_pid" ] || [ "$main_pid" = "0" ] || [ ! -e "/proc/$main_pid" ]; then
          echo "hercules-ci-agent-config-restarter: agent is not running; no restart needed."
          stop_retry_timer
          exit 0
        fi

        running_config=""
        previous_arg=""
        while IFS= read -r arg; do
          if [ "$previous_arg" = "--config" ]; then
            running_config="$arg"
            break
          fi
          previous_arg="$arg"
        done < <(${pkgs.coreutils}/bin/tr '\0' '\n' < "/proc/$main_pid/cmdline")

        running_bin="$(${pkgs.coreutils}/bin/readlink -f "/proc/$main_pid/exe" 2>/dev/null || true)"
        expected_bin="$(${pkgs.coreutils}/bin/readlink -f "${agentBin}" 2>/dev/null || true)"

        if [ "$running_config" != "${agentConfigPath}" ]; then
          restart_or_defer "config changed from ''${running_config:-unknown} to ${agentConfigPath}."
        fi

        if [ -n "$running_bin" ] && [ -n "$expected_bin" ] && [ "$running_bin" != "$expected_bin" ]; then
          restart_or_defer "binary changed from $running_bin to $expected_bin."
        fi

        stop_retry_timer
        echo "hercules-ci-agent-config-restarter: running agent is current."
      '';
    };

    systemd.services.hercules-ci-agent-config-restarter-retry = {
      description = "Retry Hercules CI Agent stale restart check";
      serviceConfig.Type = "oneshot";
      script = ''
        ${pkgs.systemd}/bin/systemctl restart hercules-ci-agent-config-restarter.service
      '';
    };

    systemd.timers.hercules-ci-agent-config-restarter-retry = {
      description = "Retry Hercules CI Agent stale restart check";
      timerConfig = {
        OnActiveSec = "2min";
        AccuracySec = "10s";
        Unit = "hercules-ci-agent-config-restarter-retry.service";
      };
    };

    # HCI executes an effect derivation's builder inside the local effect
    # container. Mark only native x86_64 Linux agents for x86_64 effects; remote
    # builders and substituters can realise paths, but they cannot make an
    # aarch64 agent execute an x86_64 builder.
    nix.settings.extra-system-features =
      lib.optionals (host.system == "x86_64-linux") ["hci-x86_64-effect-runner"];
  };

  den.aspects.hercules.prewarm.nixos = {
    config,
    pkgs,
    ...
  }: let
    prewarmScript = pkgs.writeShellApplication {
      name = "hci-prewarm-configurations";
      runtimeInputs = with pkgs; [
        coreutils
        curl
        findutils
        gawk
        gitMinimal
        gnugrep
        jq
        nix
        systemd
        util-linux
      ];
      text = builtins.readFile ./scripts/hci-prewarm-configurations.sh;
    };

    agentHasWorkers = pkgs.writeShellApplication {
      name = "hci-agent-has-workers";
      runtimeInputs = with pkgs; [
        coreutils
        findutils
        systemd
      ];
      text = ''
        control_group="$(systemctl show -p ControlGroup --value hercules-ci-agent.service 2>/dev/null || true)"
        if [ -z "$control_group" ]; then
          echo "hci-prewarm: could not determine Hercules CI agent control group; skipping prewarm."
          exit 1
        fi

        cgroup_dir="/sys/fs/cgroup$control_group"
        if [ ! -d "$cgroup_dir" ]; then
          echo "hci-prewarm: cannot inspect $cgroup_dir; skipping prewarm."
          exit 1
        fi

        found_proc_file=0
        while IFS= read -r -d "" cgroup_procs; do
          found_proc_file=1
          while IFS= read -r pid; do
            if [ -z "$pid" ] || [ ! -r "/proc/$pid/cmdline" ]; then
              continue
            fi

            cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" || true)"
            case "$cmdline" in
              *hercules-ci-agent-worker*)
                echo "hci-prewarm: active Hercules CI worker pid $pid: $cmdline"
                exit 1
                ;;
            esac
          done < "$cgroup_procs"
        done < <(find "$cgroup_dir" -name cgroup.procs -type f -readable -print0)

        if [ "$found_proc_file" = "0" ]; then
          echo "hci-prewarm: found no readable cgroup.procs files below $cgroup_dir; skipping prewarm."
          exit 1
        fi

        exit 0
      '';
    };
  in {
    assertions = [
      {
        assertion = config.services.hercules-ci-agent.enable or false;
        message = "den.aspects.hercules.prewarm requires services.hercules-ci-agent.enable = true.";
      }
    ];

    nix.settings = {
      keep-derivations = true;
      keep-outputs = true;
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/hci-prewarm 0755 root root -"
      "d /nix/var/nix/gcroots/hci-prewarm 0755 root root -"
    ];

    systemd.services.hci-prewarm-configurations = {
      description = "Prewarm Hercules CI configuration closures";
      after = ["network-online.target" "hercules-ci-agent.service"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecCondition = "${agentHasWorkers}/bin/hci-agent-has-workers";
        ExecStart = "${prewarmScript}/bin/hci-prewarm-configurations";
        Nice = 19;
        IOSchedulingClass = "idle";
        IOSchedulingPriority = 7;
        CPUWeight = 10;
        IOWeight = 10;
        MemoryHigh = "512M";
        MemoryMax = "2G";
        TasksMax = 256;
        OOMPolicy = "stop";
      };
      environment = {
        HCI_PREWARM_REPO_URL = "https://github.com/whitestrake/nixos.git";
        HCI_PREWARM_BRANCH = "master";
        HCI_PREWARM_CHECKOUT_DIR = "/var/lib/hci-prewarm/nixos";
        HCI_PREWARM_GCROOT_DIR = "/nix/var/nix/gcroots/hci-prewarm";
        HCI_PREWARM_KEEP_REVISIONS = "3";
        HCI_PREWARM_HCI_PROJECT = "github/whitestrake/nixos";
        HCI_PREWARM_HCI_MASTER_REF = "refs/heads/master";
        HCI_PREWARM_HCI_LATEST_JOBS = "200";
        HCI_PREWARM_SLEEP_SECONDS = "120";
        HCI_PREWARM_LOCK_FILE = "/run/hci-prewarm-configurations.lock";
        HCI_PREWARM_AGENT_SERVICE = "hercules-ci-agent.service";
      };
    };

    systemd.timers.hci-prewarm-configurations = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "hourly";
        RandomizedDelaySec = "20min";
        Persistent = true;
        AccuracySec = "5min";
        Unit = "hci-prewarm-configurations.service";
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

    # Let HCI treat nixbuild.net as capable of Linux work matching local features.
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

  # Socket-activated remote builder backed by ephemeral Namespace macOS instances.
  # Include this on one host only; every cold Darwin build can create paid runtime.
  den.aspects.hercules.namespace-darwin-broker.nixos = {
    config,
    host,
    pkgs,
    lib,
    ...
  }: let
    # Enables verbose broker script logging for live namespace-mac debugging.
    enableBrokerDebug = false;

    # The Hercules agent user owns all Namespace CLI credentials and runtime state.
    agentUser = config.systemd.services.hercules-ci-agent.serviceConfig.User;

    # Runtime-generated SSH key used for native Namespace SSH and guest root SSH.
    runtimeKeyPath = "/run/namespace-darwin-builder/id_ed25519";

    # Shared broker shell library sourced by the broker lifecycle scripts.
    darwin-broker-common =
      pkgs.writeText "darwin-broker-common.sh"
      (builtins.readFile ./scripts/darwin-broker-common.sh);

    # Guest-side bootstrap payload uploaded over native Namespace SSH.
    darwin-guest-bootstrap =
      pkgs.writeText "darwin-guest-bootstrap.sh"
      (builtins.readFile ./scripts/darwin-guest-bootstrap.sh);

    # Boot/setup phase: generate the runtime SSH key and purge stale instances.
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

    # Hot provisioning phase: create/reuse an instance and bootstrap the guest.
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

    # Shared cleanup phase: kill tunnels and destroy the state-tracked instance.
    darwin-broker-cleanup = pkgs.writeShellApplication {
      name = "darwin-broker-cleanup";
      runtimeInputs = with pkgs; [
        coreutils
        jq
        namespace-cli
      ];
      text = builtins.readFile ./scripts/darwin-broker-cleanup.sh;
    };

    # Socket service entrypoint: ensure an instance, tunnel SSH, then proxy stdin.
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

    # Periodic idle/failure cleanup path kept out of the hot provisioning path.
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
    # nsc currently resolves Namespace's API endpoint to IPv4 on sortie. dhcpcd's
    # default "any" can satisfy network-online.target before IPv4 routing exists.
    networking.dhcpcd.wait = lib.mkDefault "ipv4";

    # Namespace API token consumed by nsc for instance create/list/destroy calls.
    sops.secrets.namespaceToken.owner = agentUser;

    # Runtime state for generated SSH keys, leases, tunnel pids, and markers.
    systemd.tmpfiles.rules = [
      "d /run/namespace-darwin-builder 0700 ${agentUser} ${agentUser} -"
    ];

    # Nix connects to this alias; systemd socket activation wakes the proxy.
    programs.ssh.extraConfig = ''
      Host namespace-mac
        HostName 127.0.0.1
        Port 22022
        User root
        IdentityFile ${runtimeKeyPath}
        BatchMode yes
        IdentitiesOnly yes
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
    '';

    # Local ssh-ng listener for Nix; the service below accepts and proxies it.
    systemd.sockets.namespace-mac = {
      wantedBy = ["multi-user.target"];
      socketConfig = {
        ListenStream = "127.0.0.1:22022";
        Backlog = 128;
        Accept = false;
        NoDelay = true;
      };
    };

    # Hot path service for Nix builder connections: provision/bootstrap the
    # Namespace guest, create the local root SSH tunnel, then proxy this socket.
    systemd.services.namespace-mac = {
      description = "Namespace macOS SSH socket proxy";
      requires = ["namespace-darwin-builder-init.service"];
      after = ["network-online.target" "namespace-darwin-builder-init.service"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "simple";
        User = agentUser;
        Environment = [
          "NSC_TOKEN_FILE=${config.sops.secrets.namespaceToken.path}"
          "NAMESPACE_BUILDER_KEY_PATH=${runtimeKeyPath}"
          "NAMESPACE_DARWIN_BROKER_NAME=${host.name}"
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

    # Boot one-shot: create the ephemeral SSH key and remove stale labeled
    # instances left by a previous boot before the socket can be used.
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
          "NSC_TOKEN_FILE=${config.sops.secrets.namespaceToken.path}"
          "NAMESPACE_BUILDER_KEY_PATH=${runtimeKeyPath}"
          "NAMESPACE_DARWIN_BROKER_NAME=${host.name}"
          "NAMESPACE_DARWIN_BROKER_COMMON=${darwin-broker-common}"
          "NAMESPACE_DARWIN_RUN_DIR=/run/namespace-darwin-builder"
          "NAMESPACE_DARWIN_BROKER_DEBUG=${lib.boolToString enableBrokerDebug}"
        ];
        ExecStart = "${darwin-broker-init}/bin/darwin-broker-init";
        Restart = "on-failure";
        RestartSec = "5s";
        RestartSteps = 6;
        RestartMaxDelaySec = "30s";
      };
      startLimitBurst = 8;
      startLimitIntervalSec = 180;
    };

    # Timer target: reap idle instances and handle recent failure markers without
    # putting labeled nsc list/purge work in the provisioning hot path.
    systemd.services.namespace-darwin-builder-reaper = {
      description = "Reap idle Namespace macOS builder instances";
      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "NSC_TOKEN_FILE=${config.sops.secrets.namespaceToken.path}"
          "NAMESPACE_DARWIN_BROKER_NAME=${host.name}"
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

    # Run the reaper frequently; it exits immediately while namespace-mac is active.
    systemd.timers.namespace-darwin-builder-reaper = {
      description = "Timer for Namespace macOS builder reaper";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
        AccuracySec = "5s";
      };
    };

    # Let HCI schedule Darwin outputs here; Nix then sends them to namespace-mac.
    services.hercules-ci-agent.settings.remotePlatformsWithSameFeatures = [
      "aarch64-darwin"
    ];

    # Expose namespace-mac to Nix as the aarch64-darwin ssh-ng remote builder.
    nix = {
      distributedBuilds = true;
      settings.builders-use-substitutes = true;
      buildMachines = [
        {
          hostName = "namespace-mac";
          system = "aarch64-darwin";
          maxJobs = 3;
          supportedFeatures = ["big-parallel"];
          protocol = "ssh-ng";
        }
      ];
    };
  };
}
