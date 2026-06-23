{den, ...} @ flake: {
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
        concurrentTasks = 6;
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

    # Namespace builder public key
    pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF3H1NMNRQI83JrofeftT90IgyGadDKKeVJ+xDDeyC3V namespace-builder";

    builderHost = "namespace-mac";
    brokerName = host.name;

    namespace-darwin-ensure = pkgs.writeShellApplication {
      name = "namespace-darwin-ensure";
      runtimeInputs = with pkgs; [
        namespace-cli
        jq
        coreutils
        curl
        openssh
      ];
      text = ''
        set -euo pipefail

        export NSC_TOKEN_FILE="${config.sops.secrets.namespaceHciToken.path}"
        export HOME="/run/namespace-darwin-builder"
        RUNDIR="/run/namespace-darwin-builder"
        mkdir -p "$RUNDIR"
        STATE_FILE="$RUNDIR/state.json"

        check_ssh() {
          local id="$1"
          local ssh_host="$2"
          echo "Checking SSH for existing instance $id..." >&2
          if [ -n "$ssh_host" ]; then
            echo "Checking direct SSH to $id@$ssh_host..." >&2
            if ssh -n -i "${config.sops.secrets.namespaceBuilderKey.path}" \
              -o BatchMode=yes \
              -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 \
              "$id@$ssh_host" \
              'echo SSH check' >/dev/null 2>&1; then
              return 0
            else
              echo "Direct SSH failed." >&2
              return 1
            fi
          fi
          return 1
        }

        ensure_sshd_2222() {
          local id="$1"
          local host="$2"
          echo "Ensuring custom sshd is running on port 2222 for $id..." >&2

          # Authorize the builder public key for root and runner users on macOS
          ssh -n -i "${config.sops.secrets.namespaceBuilderKey.path}" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            "$id@$host" \
            "mkdir -p ~/.ssh && echo '${pubKey}' > ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && sudo -n mkdir -p /var/root/.ssh && echo '${pubKey}' | sudo -n tee /var/root/.ssh/authorized_keys >/dev/null && sudo -n chmod 700 /var/root/.ssh && sudo -n chmod 600 /var/root/.ssh/authorized_keys"

          # Generate host keys if they do not exist
          ssh -n -i "${config.sops.secrets.namespaceBuilderKey.path}" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            "$id@$host" \
            "sudo -n ssh-keygen -A"

          # Start custom sshd on port 2222 if not already running
          ssh -n -i "${config.sops.secrets.namespaceBuilderKey.path}" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            "$id@$host" \
            "if ! sudo -n lsof -i tcp:2222 -sTCP:LISTEN -t >/dev/null 2>&1; then sudo -n /usr/sbin/sshd -p 2222 -o ListenAddress=127.0.0.1 -o PermitRootLogin=yes; fi"

          for _ in $(seq 1 10); do
            if ssh -n -i "${config.sops.secrets.namespaceBuilderKey.path}" \
                -o BatchMode=yes \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                "$id@$host" \
                "nc -z localhost 2222" >/dev/null 2>&1; then
              echo "Custom sshd is responsive!" >&2
              return 0
            fi
            sleep 1
          done
          echo "Timed out waiting for custom sshd on port 2222" >&2
          return 1
        }

        # Reuse existing valid instance from state file if possible
        if [ -f "$STATE_FILE" ]; then
          EXISTING_ID=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE" || true)
          INGRESS_DOMAIN="$(jq -r '.ingress_domain // empty' < "$STATE_FILE" || true)"
          if [ -n "$EXISTING_ID" ] && [ -n "$INGRESS_DOMAIN" ] && [ "$INGRESS_DOMAIN" != "null" ]; then
            REGION="$(echo "$INGRESS_DOMAIN" | cut -d. -f1)"
            SSH_HOST="ssh.$REGION.namespace.so"
            if check_ssh "$EXISTING_ID" "$SSH_HOST"; then
              echo "Reusing existing valid instance: $EXISTING_ID" >&2
              if ensure_sshd_2222 "$EXISTING_ID" "$SSH_HOST"; then
                date +%s > "$RUNDIR/last-used"
                exit 0
              fi
            fi
          fi
        fi

        # Find existing instance with labels
        # Since nsc list returns null when empty, jq handles it
        EXISTING_ID=$(
          nsc list -o json | jq -r '
            .[]? |
            ( if .labels | type == "array" then
                reduce .labels[] as $l ({}; .[$l.name] = $l.value)
              elif .labels | type == "object" then
                .labels
              elif .label | type == "array" then
                reduce .label[] as $l ({}; .[$l.name] = $l.value)
              else
                {}
              end
            ) as $lbls |
            select(
              $lbls.purpose == "hci-darwin-builder" and
              $lbls.repo == "whitestrake/nixos" and
              $lbls.broker == "'"${brokerName}"'"
            ) | .instance_id // .cluster_id // .id // empty
          ' | head -n 1 || true
        )

        if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "null" ]; then
          nsc describe "$EXISTING_ID" -o json > "$STATE_FILE.candidate"
          INGRESS_DOMAIN="$(jq -r '.ingress_domain // empty' < "$STATE_FILE.candidate" || true)"
          if [ -z "$INGRESS_DOMAIN" ] || [ "$INGRESS_DOMAIN" = "null" ]; then
            nsc list -o json | jq --arg id "$EXISTING_ID" '.[]? | select(.instance_id == $id or .cluster_id == $id or .id == $id)' > "$STATE_FILE.candidate"
            INGRESS_DOMAIN="$(jq -r '.ingress_domain // empty' < "$STATE_FILE.candidate" || true)"
          fi
          if [ -n "$INGRESS_DOMAIN" ] && [ "$INGRESS_DOMAIN" != "null" ]; then
            REGION="$(echo "$INGRESS_DOMAIN" | cut -d. -f1)"
            SSH_HOST="ssh.$REGION.namespace.so"
            if check_ssh "$EXISTING_ID" "$SSH_HOST"; then
              echo "Found running instance with matching labels: $EXISTING_ID" >&2
              if ensure_sshd_2222 "$EXISTING_ID" "$SSH_HOST"; then
                mv "$STATE_FILE.candidate" "$STATE_FILE"
                date +%s > "$RUNDIR/last-used"
                exit 0
              fi
            fi
          fi
          rm -f "$STATE_FILE.candidate"
        fi

        echo "Creating macOS instance on Namespace.so..." >&2
        INSTANCE_JSON=$(nsc create \
          --machine_type macos/arm64:6x14 \
          --bare \
          --duration 30m \
          --ssh_key <(echo "${pubKey}") \
          --label "purpose=hci-darwin-builder" \
          --label "repo=whitestrake/nixos" \
          --label "broker=${brokerName}" \
          -o json)

        INSTANCE_ID=$(echo "$INSTANCE_JSON" | jq -r '.instance_id // .cluster_id // .id // empty')
        if [ -z "$INSTANCE_ID" ]; then
          echo "Failed to parse instance ID!" >&2
          exit 1
        fi

        INGRESS_DOMAIN="$(echo "$INSTANCE_JSON" | jq -r '.ingress_domain // empty')"
        if [ -z "$INGRESS_DOMAIN" ] || [ "$INGRESS_DOMAIN" = "null" ]; then
          echo "Created Namespace instance has no ingress_domain; direct SSH required for builder." >&2
          nsc destroy "$INSTANCE_ID" --force || true
          exit 1
        fi

        REGION="$(echo "$INGRESS_DOMAIN" | cut -d. -f1)"
        if [ -z "$REGION" ] || [ "$REGION" = "null" ]; then
          echo "Could not derive Namespace region from created instance ingress_domain: $INGRESS_DOMAIN" >&2
          nsc destroy "$INSTANCE_ID" --force || true
          exit 1
        fi

        SSH_HOST="ssh.$REGION.namespace.so"

        # Save Namespace state immediately after create
        echo "$INSTANCE_JSON" > "$STATE_FILE"
        date +%s > "$RUNDIR/last-used"

        # Wait for SSH to be responsive
        echo "Waiting for SSH to become responsive..." >&2
        for i in $(seq 1 30); do
          if check_ssh "$INSTANCE_ID" "$SSH_HOST"; then
            echo "SSH is responsive!" >&2
            break
          fi
          if [ "$i" -eq 30 ]; then
            echo "Timed out waiting for SSH response." >&2
            exit 1
          fi
          sleep 2
        done

        if ! ensure_sshd_2222 "$INSTANCE_ID" "$SSH_HOST"; then
          exit 1
        fi

        # Ensure root user shell is /bin/zsh so non-interactive SSH connections source /etc/zshenv
        ssh -n -i "${config.sops.secrets.namespaceBuilderKey.path}" \
          -o BatchMode=yes \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          "$INSTANCE_ID@$SSH_HOST" \
          "sudo -n dscl . -create /Users/root UserShell /bin/zsh" >/dev/null 2>&1 || true

        # Install Nix on macOS if not present
        echo "Checking for Nix on instance..." >&2
        if ! ssh -n -i "${config.sops.secrets.namespaceBuilderKey.path}" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            "$INSTANCE_ID@$SSH_HOST" \
            "command -v nix" >/dev/null 2>&1; then
          echo "Nix not found. Installing Nix..." >&2
          if ! ssh -n -i "${config.sops.secrets.namespaceBuilderKey.path}" \
              -o BatchMode=yes \
              -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null \
              "$INSTANCE_ID@$SSH_HOST" \
              "curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm" >&2; then
            echo "Nix installation failed!" >&2
            exit 1
          fi
          echo "Nix installed successfully." >&2
        else
          echo "Nix is already installed." >&2
        fi

        # Ensure Nix binaries are available in standard PATH for non-interactive SSH
        ssh -n -i "${config.sops.secrets.namespaceBuilderKey.path}" \
          -o BatchMode=yes \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          "$INSTANCE_ID@$SSH_HOST" \
          "sudo -n mkdir -p /usr/local/bin && sudo -n ln -sf /nix/var/nix/profiles/default/bin/nix* /usr/local/bin/" \
          >/dev/null 2>&1 || true

        # Save state
        echo "$INSTANCE_JSON" > "$STATE_FILE"
        date +%s > "$RUNDIR/last-used"
      '';
    };

    namespace-darwin-cleanup = pkgs.writeShellApplication {
      name = "namespace-darwin-cleanup";
      runtimeInputs = with pkgs; [
        coreutils
        jq
        openssh
        namespace-cli
      ];
      text = ''
        export NSC_TOKEN_FILE="${config.sops.secrets.namespaceHciToken.path}"
        export HOME="/run/namespace-darwin-builder"
        RUNDIR="/run/namespace-darwin-builder"
        TUNNEL_PID_FILE="$RUNDIR/tunnel.pid"
        STATE_FILE="$RUNDIR/state.json"

        # Kill the tunnel process if it exists
        if [ -f "$TUNNEL_PID_FILE" ]; then
          TUNNEL_PID=$(cat "$TUNNEL_PID_FILE" 2>/dev/null || true)
          if [ -n "$TUNNEL_PID" ]; then
            echo "Killing SSH tunnel PID $TUNNEL_PID..." >&2
            kill "$TUNNEL_PID" 2>/dev/null || true
            wait "$TUNNEL_PID" 2>/dev/null || true
          fi
        fi

        # Destroy the Namespace instance if state exists
        if [ -f "$STATE_FILE" ]; then
          INSTANCE_ID=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE" 2>/dev/null || true)
          if [ -n "$INSTANCE_ID" ]; then
            echo "Destroying Namespace instance $INSTANCE_ID..." >&2
            nsc destroy "$INSTANCE_ID" --force || true
          fi
        fi

        # Clean up files
        rm -f "$STATE_FILE" "$TUNNEL_PID_FILE" "$RUNDIR/last-used"
      '';
    };

    namespace-darwin-socket-proxy = pkgs.writeShellApplication {
      name = "namespace-darwin-socket-proxy";
      runtimeInputs = with pkgs; [
        coreutils
        jq
        openssh
        netcat
        namespace-cli
        namespace-darwin-ensure
      ];
      text = ''
        set -euo pipefail

        export NSC_TOKEN_FILE="${config.sops.secrets.namespaceHciToken.path}"
        export HOME="/run/namespace-darwin-builder"
        RUNDIR="/run/namespace-darwin-builder"
        mkdir -p "$RUNDIR"

        STATE_FILE="$RUNDIR/state.json"
        UPSTREAM_PORT=22023

        # Run provisioning with fd 3 closed
        if ! namespace-darwin-ensure 3<&- >&2; then
          echo "Failed to provision namespace instance." >&2
          exit 1
        fi

        if [ ! -s "$STATE_FILE" ]; then
          echo "Namespace state file missing or empty after ensure: $STATE_FILE" >&2
          exit 1
        fi

        instance_id=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE")
        ingress_domain=$(jq -r '.ingress_domain // empty' < "$STATE_FILE")
        region=$(printf '%s\n' "$ingress_domain" | cut -d. -f1)
        if [ -z "$instance_id" ] || [ "$instance_id" = "null" ] || [ -z "$region" ] || [ "$region" = "null" ]; then
          echo "Invalid namespace state; missing instance_id or region." >&2
          echo "state=$(cat "$STATE_FILE")" >&2
          exit 1
        fi

        ssh_host="ssh.$region.namespace.so"

        # Start local SSH tunnel and write its PID
        ssh -nNT \
          -i "${config.sops.secrets.namespaceBuilderKey.path}" \
          -o BatchMode=yes \
          -o IdentitiesOnly=yes \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ServerAliveInterval=10 \
          -o ServerAliveCountMax=3 \
          -L "127.0.0.1:$UPSTREAM_PORT:localhost:2222" \
          "$instance_id@$ssh_host" \
          3<&- &
        TUNNEL_PID=$!
        echo "$TUNNEL_PID" > "$RUNDIR/tunnel.pid"

        # Wait until local tunnel port is responsive
        for _ in $(seq 1 100); do
          if nc -z 127.0.0.1 "$UPSTREAM_PORT"; then
            break
          fi
          sleep 0.1
        done
        if ! nc -z 127.0.0.1 "$UPSTREAM_PORT"; then
          echo "Timed out waiting for Namespace SSH tunnel on local port $UPSTREAM_PORT" >&2
          kill "$TUNNEL_PID" 2>/dev/null || true
          wait "$TUNNEL_PID" 2>/dev/null || true
          exit 1
        fi

        # Exec systemd-socket-proxyd
        exec ${config.systemd.package}/lib/systemd/systemd-socket-proxyd \
          --connections-max=64 \
          --exit-idle-time=20s \
          "127.0.0.1:$UPSTREAM_PORT"
      '';
    };

    namespace-darwin-reaper = pkgs.writeShellApplication {
      name = "namespace-darwin-reaper";
      runtimeInputs = with pkgs; [
        namespace-cli
        jq
        coreutils
        systemd
      ];
      text = ''
        export NSC_TOKEN_FILE="${config.sops.secrets.namespaceHciToken.path}"
        export HOME="/run/namespace-darwin-builder"
        RUNDIR="/run/namespace-darwin-builder"
        STATE_FILE="$RUNDIR/state.json"

        if ! systemctl is-active -q namespace-mac.service; then
          if [ -f "$STATE_FILE" ]; then
            instance_id=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE" 2>/dev/null || true)
            if [ -n "$instance_id" ]; then
              echo "Service is inactive but state file exists. Destroying leaked instance $instance_id..." >&2
              nsc destroy "$instance_id" --force || true
            fi
            rm -f "$STATE_FILE" "$RUNDIR/tunnel.pid" "$RUNDIR/last-used"
          fi
        fi
      '';
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
        ExecStart = "${namespace-darwin-socket-proxy}/bin/namespace-darwin-socket-proxy";
        ExecStopPost = "${namespace-darwin-cleanup}/bin/namespace-darwin-cleanup";
        TimeoutStartSec = "10min";
        TimeoutStopSec = "30s";
        KillMode = "mixed";
        Restart = "on-failure";
        RestartSec = "2s";
        StartLimitBurst = 12;
        StartLimitIntervalSec = "2min";
      };
    };

    systemd.services.namespace-darwin-builder-reaper = {
      description = "Reap idle Namespace macOS builder instances";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${namespace-darwin-reaper}/bin/namespace-darwin-reaper";
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
