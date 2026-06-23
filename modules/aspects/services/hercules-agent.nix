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
        util-linux
      ];
      text = ''
        export NSC_TOKEN_FILE="${config.sops.secrets.namespaceHciToken.path}"
        export HOME="/run/namespace-darwin-builder"
        RUNDIR="/run/namespace-darwin-builder"
        mkdir -p "$RUNDIR"

        # Use FD 200 for flock
        exec 200>"$RUNDIR/lock"
        flock 200

        STATE_FILE="$RUNDIR/state.json"

        adjust_permissions() {
          if [ "$(id -u)" -eq 0 ]; then
            chown -R ${agentUser}:${agentUser} "$RUNDIR" || true
          fi
        }
        trap adjust_permissions EXIT

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

          for i in $(seq 1 10); do
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

        if [ -f "$STATE_FILE" ]; then
          EXISTING_ID=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE" || true)
          if [ -n "$EXISTING_ID" ]; then
            INGRESS_DOMAIN="$(jq -r '.ingress_domain // empty' < "$STATE_FILE" || true)"
            if [ -z "$INGRESS_DOMAIN" ]; then
              echo "State file has no ingress_domain; direct SSH not possible." >&2
            else
              REGION="$(echo "$INGRESS_DOMAIN" | cut -d. -f1)"
              if [ -z "$REGION" ]; then
                echo "Could not derive Namespace region from state file ingress_domain: $INGRESS_DOMAIN" >&2
              else
                SSH_HOST="ssh.$REGION.namespace.so"
                if check_ssh "$EXISTING_ID" "$SSH_HOST"; then
                  echo "Reusing existing valid instance: $EXISTING_ID" >&2
                  if ! ensure_sshd_2222 "$EXISTING_ID" "$SSH_HOST"; then
                    exit 1
                  fi
                  date +%s > "$RUNDIR/last-used"
                  exit 0
                fi
              fi
            fi
          fi
          # State file invalid or unreachable, continue
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
          if [ -z "$INGRESS_DOMAIN" ] || [ "$INGRESS_DOMAIN" = "null" ]; then
            echo "Candidate Namespace instance $EXISTING_ID has no ingress_domain; direct SSH not possible." >&2
            rm -f "$STATE_FILE.candidate"
          else
            REGION="$(echo "$INGRESS_DOMAIN" | cut -d. -f1)"
            if [ -z "$REGION" ]; then
              echo "Could not derive Namespace region from candidate ingress_domain: $INGRESS_DOMAIN" >&2
              rm -f "$STATE_FILE.candidate"
            else
              SSH_HOST="ssh.$REGION.namespace.so"
              if check_ssh "$EXISTING_ID" "$SSH_HOST"; then
                echo "Found running instance with matching labels: $EXISTING_ID" >&2
                if ! ensure_sshd_2222 "$EXISTING_ID" "$SSH_HOST"; then
                  exit 1
                fi
                mv "$STATE_FILE.candidate" "$STATE_FILE"
                date +%s > "$RUNDIR/last-used"
                exit 0
              fi
              rm -f "$STATE_FILE.candidate"
            fi
          fi
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
        if [ -z "$INGRESS_DOMAIN" ]; then
          echo "Created Namespace instance has no ingress_domain; direct SSH required for builder." >&2
          nsc destroy "$INSTANCE_ID" --force || true
          exit 1
        fi

        REGION="$(echo "$INGRESS_DOMAIN" | cut -d. -f1)"
        if [ -z "$REGION" ]; then
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

    namespace-darwin-proxy = pkgs.writeShellApplication {
      name = "namespace-darwin-proxy";
      runtimeInputs = with pkgs; [
        coreutils
        jq
        openssh
        namespace-darwin-ensure
        gawk
      ];
      text = ''
        RUNDIR="/run/namespace-darwin-builder"
        STATE_FILE="$RUNDIR/state.json"
        ACTIVE_DIR="$RUNDIR/active"

        mkdir -p "$ACTIVE_DIR"
        MARKER="$ACTIVE_DIR/$$"

        proc_start_time() {
          awk '{print $22}' "/proc/$$/stat"
        }

        write_marker() {
          phase="$1"
          now="$(date +%s)"
          proc_start="$(proc_start_time)"

          printf 'pid=%s\nproc_start=%s\nstarted=%s\nphase=%s\n' "$$" "$proc_start" "$now" "$phase" > "$MARKER.tmp"
          mv "$MARKER.tmp" "$MARKER"
        }

        cleanup() {
          rm -f "$MARKER"
          date +%s > "$RUNDIR/last-used"
          if [ "$(id -u)" -eq 0 ]; then
            chown -R ${agentUser}:${agentUser} "$RUNDIR" || true
          fi
        }

        write_marker starting
        trap cleanup EXIT HUP INT TERM

        namespace-darwin-ensure >&2

        INSTANCE_ID=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE")
        INGRESS_DOMAIN=$(jq -r '.ingress_domain // empty' < "$STATE_FILE")

        if [ -z "$INGRESS_DOMAIN" ]; then
          echo "Namespace instance has no ingress_domain; cannot establish direct SSH proxy." >&2
          exit 1
        fi

        REGION=$(echo "$INGRESS_DOMAIN" | cut -d. -f1)

        if [ -z "$REGION" ]; then
          echo "Could not derive Namespace region from ingress_domain: $INGRESS_DOMAIN" >&2
          exit 1
        fi

        SSH_HOST="ssh.$REGION.namespace.so"

        write_marker connected

        # Close parent shell stderr to prevent log pipe deadlocks
        exec 2>/dev/null

        ssh -i "${config.sops.secrets.namespaceBuilderKey.path}" \
          -o BatchMode=yes \
          -o IdentitiesOnly=yes \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -W localhost:2222 \
          "$INSTANCE_ID@$SSH_HOST" <&0 >&1 &
        SSH_PID=$!

        # Close parent shell FDs to avoid pipe inheritance deadlocks
        exec 0<&-
        exec 1>&-

        wait "$SSH_PID"
      '';
    };

    namespace-darwin-reaper = pkgs.writeShellApplication {
      name = "namespace-darwin-reaper";
      runtimeInputs = with pkgs; [
        namespace-cli
        jq
        coreutils
        util-linux
        gawk
        procps
      ];
      text = ''
        export NSC_TOKEN_FILE="${config.sops.secrets.namespaceHciToken.path}"
        export HOME="/run/namespace-darwin-builder"
        RUNDIR="/run/namespace-darwin-builder"
        STATE_FILE="$RUNDIR/state.json"
        ACTIVE_DIR="$RUNDIR/active"
        LAST_USED_FILE="$RUNDIR/last-used"

        IDLE_LIMIT=20
        STALE_MARKER_LIMIT=300

        adjust_permissions() {
          if [ "$(id -u)" -eq 0 ]; then
            chown -R ${agentUser}:${agentUser} "$RUNDIR" || true
          fi
        }
        trap adjust_permissions EXIT

        marker_field() {
          key="$1"
          marker="$2"
          awk -F= -v k="$key" '$1 == k {print substr($0, length(k) + 2); exit}' "$marker"
        }

        same_process() {
          pid="$1"
          expected_start="$2"

          [ -r "/proc/$pid/stat" ] || return 1

          current_start="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"
          [ "$current_start" = "$expected_start" ]
        }

        kill_marker_process() {
          pid="$1"

          echo "Killing stale Namespace proxy process tree for pid $pid..." >&2
          pkill -TERM -P "$pid" 2>/dev/null || true
          kill -TERM "$pid" 2>/dev/null || true
          sleep 2
          pkill -KILL -P "$pid" 2>/dev/null || true
          kill -KILL "$pid" 2>/dev/null || true
        }

        prune_markers() {
          active=0
          now="$(date +%s)"

          mkdir -p "$ACTIVE_DIR"

          for marker in "$ACTIVE_DIR"/*; do
            [ -f "$marker" ] || continue

            pid="$(marker_field pid "$marker" || true)"
            proc_start="$(marker_field proc_start "$marker" || true)"
            started="$(marker_field started "$marker" || true)"
            phase="$(marker_field phase "$marker" || true)"

            if [ -z "$pid" ] || [ -z "$proc_start" ] || [ -z "$started" ] || [ -z "$phase" ]; then
              echo "Removing malformed marker: $marker" >&2
              rm -f "$marker"
              date +%s > "$LAST_USED_FILE"
              continue
            fi

            if ! same_process "$pid" "$proc_start"; then
              echo "Removing dead or PID-reused marker: $marker" >&2
              rm -f "$marker"
              date +%s > "$LAST_USED_FILE"
              continue
            fi

            age=$((now - started))

            if [ "$phase" = "starting" ] && [ "$age" -ge "$STALE_MARKER_LIMIT" ]; then
              echo "Marker $marker stuck in starting phase for $age s." >&2
              kill_marker_process "$pid"
              rm -f "$marker"
              date +%s > "$LAST_USED_FILE"
              continue
            fi

            active=1
          done
        }

        # Run before lock so a stuck ensure/proxy can be killed even if it holds the lock.
        prune_markers

        if [ ! -f "$STATE_FILE" ]; then
          exit 0
        fi

        exec 200>"$RUNDIR/lock"
        if ! flock -w 1 200; then
          echo "Could not acquire lock, skipping reap..." >&2
          exit 0
        fi

        if [ ! -f "$STATE_FILE" ]; then
          exit 0
        fi

        INSTANCE_ID=$(jq -r '.instance_id // .cluster_id // .id // empty' < "$STATE_FILE" || true)
        if [ -z "$INSTANCE_ID" ]; then
          echo "No parseable instance ID in state file, removing..." >&2
          rm -f "$STATE_FILE"
          exit 0
        fi

        prune_markers

        if [ "$active" -eq 1 ]; then
          echo "Active Namespace proxy sessions found. Extending TTL..." >&2
          nsc extend "$INSTANCE_ID" --ensure_minimum 10m || true
          exit 0
        fi

        now="$(date +%s)"
        last_used="$(cat "$LAST_USED_FILE" 2>/dev/null || echo "$now")"
        idle=$((now - last_used))

        if [ "$idle" -ge "$IDLE_LIMIT" ]; then
          echo "Instance $INSTANCE_ID idle for $idle s. Destroying..." >&2
          nsc destroy "$INSTANCE_ID" --force || true
          rm -f "$STATE_FILE" "$LAST_USED_FILE"
          rm -f "$ACTIVE_DIR"/*
        fi
      '';
    };
  in {
    # Secrets configuration
    sops.secrets.namespaceBuilderKey.owner = agentUser;
    sops.secrets.namespaceHciToken.owner = agentUser;

    systemd.tmpfiles.rules = [
      "d /run/namespace-darwin-builder 0700 ${agentUser} ${agentUser} -"
      "d /run/namespace-darwin-builder/active 0700 ${agentUser} ${agentUser} -"
    ];

    # SSH configuration mapping the builder host to the wrapper script
    programs.ssh.extraConfig = ''
      Host ${builderHost}
        HostName ${builderHost}
        User root
        IdentityFile ${config.sops.secrets.namespaceBuilderKey.path}
        ProxyCommand ${namespace-darwin-proxy}/bin/namespace-darwin-proxy
        BatchMode yes
        IdentitiesOnly yes
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
    '';

    systemd.services.namespace-darwin-builder-reaper = {
      description = "Reap idle Namespace macOS builder instances";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${namespace-darwin-reaper}/bin/namespace-darwin-reaper";
        User = "root";
      };
    };

    systemd.timers.namespace-darwin-builder-reaper = {
      description = "Timer for Namespace macOS builder reaper";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "10s";
        OnUnitActiveSec = "5s";
        AccuracySec = "1s";
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
