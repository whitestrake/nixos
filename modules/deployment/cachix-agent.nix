{
  self,
  lib,
  ...
}: {
  den.default.nixos = {...}: {
    options.den.deploy.health = {
      requiredSystemdUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Systemd units that must be active after Cachix Deploy activation.";
      };

      requiredCommands = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "Named shell commands that must succeed after Cachix Deploy activation.";
      };
    };
  };

  den.aspects.cachix-agent.nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    hostName = config.networking.hostName;
    healthCfg = config.den.deploy.health;

    unitCheckBudget = unit:
      if unit == "tailscaled.service"
      then {
        attempts = "45";
        delay = "2";
      }
      else {
        attempts = "15";
        delay = "2";
      };

    commandCheckBudget = cmdName:
      if cmdName == "tailscale"
      then {
        attempts = "45";
        delay = "2";
      }
      else {
        attempts = "-";
        delay = "-";
      };

    unitChecks =
      map (unit: let
        budget = unitCheckBudget unit;
      in ''
        check_or_fail "systemd unit ${unit} failed health check" "systemd-unit-${unit}" ${budget.attempts} ${budget.delay} check_systemd_unit "${unit}"
      '')
      healthCfg.requiredSystemdUnits;

    commandChecks =
      lib.mapAttrsToList (cmdName: cmd: let
        budget = commandCheckBudget cmdName;
      in ''
        check_or_fail "command ${cmdName} failed health check" "command-${cmdName}" ${budget.attempts} ${budget.delay} check_command ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg cmd}
      '')
      healthCfg.requiredCommands;

    agentRestartCheck = let
      expected_bin = lib.getExe config.services.cachix-agent.package;
    in ''
      # Check if the Cachix Agent binary changed during this switch. If so,
      # schedule a delayed asynchronous restart via systemd-run. The delay
      # gives the agent time to finish reporting the successful deployment
      # back to the Cachix Deploy service before it is restarted.
      #
      # This is best-effort: a failed systemd-run must not fail an otherwise
      # healthy deployment.
      agent_pid="$(${pkgs.systemd}/bin/systemctl show -p MainPID --value cachix-agent.service 2>/dev/null || true)"
      if [ -n "$agent_pid" ] && [ "$agent_pid" -ne 0 ] 2>/dev/null; then
        running_bin="$(${pkgs.coreutils}/bin/readlink -f "/proc/$agent_pid/exe" 2>/dev/null || true)"
        expected_bin_resolved="$(${pkgs.coreutils}/bin/readlink -f "${expected_bin}" 2>/dev/null || true)"

        if [ -n "$running_bin" ] && [ -n "$expected_bin_resolved" ] && [ "$expected_bin_resolved" != "$running_bin" ]; then
          restart_delay_seconds="''${DEPLOY_HEALTH_AGENT_RESTART_DELAY_SECONDS:-30}"
          log "Cachix Agent binary updated: $running_bin -> $expected_bin_resolved. Scheduling restart in ''${restart_delay_seconds}s..."
          ${pkgs.systemd}/bin/systemd-run \
            --unit=restart-cachix-agent-deferred \
            --description="Deferred Cachix Agent restart after deploy" \
            --collect \
            --on-active="''${restart_delay_seconds}s" \
            ${pkgs.systemd}/bin/systemctl restart cachix-agent.service \
            || log "Warning: Failed to schedule asynchronous agent restart. Agent will continue running the old binary until next restart."
        else
          log "Cachix Agent binary is up-to-date ($running_bin)."
        fi
      else
        log "Warning: Could not determine running Cachix Agent PID. Skipping agent restart check."
      fi
    '';

    hostChecks = ''
      ${lib.concatStringsSep "\n" unitChecks}
      ${lib.concatStringsSep "\n" commandChecks}
      ${agentRestartCheck}
    '';

    # Generate the rollback script text. The settle and retry environment
    # variables are intentionally runtime controls so deployments can be tuned
    # without rebuilding the flake when a host needs more time to converge.
    rollbackScriptText = ''
      # Auto-generated deploy rollback script for host ${hostName}
      set -euo pipefail

      deploy_start_epoch="$(${pkgs.coreutils}/bin/date +%s)"
      diagnostics_collected=0

      command_timeout_seconds="''${DEPLOY_HEALTH_COMMAND_TIMEOUT_SECONDS:-10}"
      systemctl_timeout_seconds="''${DEPLOY_HEALTH_SYSTEMCTL_TIMEOUT_SECONDS:-5}"
      diagnostic_timeout_seconds="''${DEPLOY_HEALTH_DIAGNOSTIC_TIMEOUT_SECONDS:-15}"
      diagnostic_journal_lines="''${DEPLOY_HEALTH_DIAGNOSTIC_JOURNAL_LINES:-300}"

      # Cleanup deployment lock file on exit (including failure exits).
      # This is intentional: if health checks fail and the deployment rolls back,
      # the lock must still be removed so the manual-switch helper is not blocked.
      cleanup_deploy_lock() {
        rm -f /run/cachix-deploy-in-progress
      }
      trap cleanup_deploy_lock EXIT

      log() { echo "deploy-health: $*" >&2; }

      run_diagnostic() {
        local name="$1"
        shift

        log "diagnostic: BEGIN $name"
        set +e
        ${pkgs.coreutils}/bin/timeout \
          --kill-after=5s \
          "$diagnostic_timeout_seconds" \
          "$@" >&2
        local rc="$?"
        set -e
        if [ "$rc" -ne 0 ]; then
          log "diagnostic: $name exited with $rc"
        fi
        log "diagnostic: END $name"
      }

      collect_diagnostics() {
        if [ "$diagnostics_collected" -eq 1 ]; then
          return 0
        fi
        diagnostics_collected=1

        set +e
        log "collecting failure diagnostics"

        run_diagnostic "systemctl-failed" \
          ${pkgs.systemd}/bin/systemctl --failed --no-pager --full

        run_diagnostic "core-service-status" \
          ${pkgs.systemd}/bin/systemctl status --no-pager --full \
            cachix-agent.service \
            tailscaled.service \
            tailscaled-autoconnect.service \
            dhcpcd.service

        run_diagnostic "mount-status" \
          ${pkgs.systemd}/bin/systemctl status --no-pager --full \
            'mnt-*.mount' \
            'mnt-*.automount'

        run_diagnostic "recent-core-journal" \
          ${pkgs.systemd}/bin/journalctl --no-pager --output=short-iso \
            --since "@$deploy_start_epoch" \
            --lines="$diagnostic_journal_lines" \
            -u cachix-agent.service \
            -u tailscaled.service \
            -u tailscaled-autoconnect.service \
            -u dhcpcd.service

        set -e
      }

      fail() {
        log "FAIL: $*"
        collect_diagnostics || true
        exit 1;
      }

      check_or_fail() {
        local failure_message="$1"
        shift
        if ! check_with_retry "$@"; then
          fail "$failure_message"
        fi
      }

      check_systemd_unit() {
        local unit="$1"
        ${pkgs.coreutils}/bin/timeout \
          --kill-after=5s \
          "$systemctl_timeout_seconds" \
          ${pkgs.systemd}/bin/systemctl is-active --quiet "$unit"
      }

      check_command() {
        ${pkgs.coreutils}/bin/timeout \
          --kill-after=5s \
          "$command_timeout_seconds" \
          "$@"
      }

      check_with_retry() {
        local name="$1"
        local attempts_override="$2"
        local delay_override="$3"
        shift 3

        local max_attempts="''${DEPLOY_HEALTH_RETRY_ATTEMPTS:-10}"
        if [ "$attempts_override" != "-" ]; then
          max_attempts="$attempts_override"
        fi

        local delay="''${DEPLOY_HEALTH_RETRY_DELAY_SECONDS:-2}"
        if [ "$delay_override" != "-" ]; then
          delay="$delay_override"
        fi

        local attempt=1
        log "Running check '$name' (max attempts: $max_attempts, delay: $delay s)..."
        while true; do
          set +e
          "$@"
          local rc="$?"
          set -e

          if [ "$rc" -eq 0 ]; then
            log "Check '$name' PASSED"
            return 0
          fi

          if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
            log "Check '$name' attempt timed out with exit code $rc"
          fi

          if [ "$attempt" -ge "$max_attempts" ]; then
            log "Check '$name' FAILED after $max_attempts attempts"
            return 1
          fi
          log "Check '$name' failed, retrying in $delay seconds (attempt $attempt/$max_attempts)..."
          sleep "$delay"
          attempt=$((attempt + 1))
        done
      }

      expected_host=${lib.escapeShellArg hostName}
      host="$(${pkgs.coreutils}/bin/cat /proc/sys/kernel/hostname)"

      if [ "$host" != "$expected_host" ]; then
        fail "deploy health script expected host $expected_host, got $host"
      fi

      log "Running health checks for $host..."
      ${hostChecks}
      log "all checks passed for $host"
    '';

    rollbackScript = pkgs.writeTextFile {
      name = "deploy-health-rollback-script-${hostName}";
      executable = true;
      text = "#!${pkgs.runtimeShell}\n${rollbackScriptText}";
      checkPhase = ''
        ${pkgs.bash}/bin/bash -n "$target"
        ${lib.getExe pkgs.shellcheck} -s bash "$target"

        if ${pkgs.gnugrep}/bin/grep -E \
          '\$\([[:space:]]*hostname[[:space:]]*\)|(^|[;&|[:space:]])hostname([[:space:]]|$)' \
          "$target"; then
          echo "rollback script must not invoke an ambient hostname binary" >&2
          exit 1
        fi

        if ${pkgs.gnugrep}/bin/grep -E '/bin/host([[:space:]]|$)' "$target"; then
          echo "rollback script must not invoke /bin/host" >&2
          exit 1
        fi

        ${pkgs.gnugrep}/bin/grep -F \
          '${pkgs.coreutils}/bin/cat /proc/sys/kernel/hostname' \
          "$target"
      '';
    };
  in {
    sops.secrets.cachixAgentToken = {};
    services.cachix-agent = {
      enable = true;
      credentialsFile = config.sops.secrets.cachixAgentToken.path;
    };
    services.networkLiveness.checks.cachix-agent = {
      inhibitPath = "/run/cachix-deploy-in-progress";
      inhibitMaxAgeSeconds = 600;
    };
    den.deploy.health.requiredSystemdUnits = ["cachix-agent.service"];

    systemd.services.nh-clean.unitConfig = lib.mkIf (config.programs.nh.clean.enable or false) {
      ConditionPathExists = "!/run/cachix-deploy-in-progress";
    };

    # Asynchronous restart changes:
    # 1. Do not restart the cachix-agent service during system switches,
    # because restarting the agent that is running switch-to-configuration
    # causes a deadlock that eventually SIGKILLs the agent and aborts/fails the deploy.
    systemd.services.cachix-agent = {
      restartIfChanged = false;
    };

    # 2. Add an activation script to detect whether the switch was triggered by
    # Cachix Deploy. When cachix-agent runs switch-to-configuration, the activation
    # process inherits the agent's cgroup (0::/system.slice/cachix-agent.service).
    # Manual switches run under a user session scope and won't match.
    system.activationScripts.cachix-deploy-lock = {
      text = ''
        if grep -q "cachix-agent.service" /proc/self/cgroup 2>/dev/null; then
          echo "cachix-deploy-lock: Cachix Deploy switch detected. Creating deployment lock."
          touch /run/cachix-deploy-in-progress
        fi
      '';
    };

    # 3. Add a helper service that checks if the cachix-agent package has been updated,
    # and restarts it if the binary changed, provided no Cachix Deploy is active.
    systemd.services.restart-cachix-agent = {
      description = "Check and restart Cachix Agent if binary changed (manual switch path)";
      wantedBy = ["multi-user.target"];
      after = ["cachix-agent.service"];
      restartTriggers = [config.services.cachix-agent.package];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
      };
      script = let
        expected_bin = lib.getExe config.services.cachix-agent.package;
      in ''
        # If a Cachix Deploy is active, exit immediately and let the deploy
        # health-check script handle the restart via systemd-run.
        if [ -f /run/cachix-deploy-in-progress ]; then
          current_time=$(${pkgs.coreutils}/bin/date +%s)
          lock_time=$(${pkgs.coreutils}/bin/stat -c %Y /run/cachix-deploy-in-progress 2>/dev/null || echo 0)
          age=$((current_time - lock_time))

          if [ "$age" -gt 600 ]; then
            echo "restart-cachix-agent: Stale deployment lock (age: ''${age}s). Removing."
            rm -f /run/cachix-deploy-in-progress
          else
            echo "restart-cachix-agent: Cachix Deploy in progress (lock age: ''${age}s). Skipping."
            exit 0
          fi
        fi

        expected_bin_resolved="$(${pkgs.coreutils}/bin/readlink -f "${expected_bin}" 2>/dev/null || true)"
        agent_pid="$(${pkgs.systemd}/bin/systemctl show -p MainPID --value cachix-agent.service 2>/dev/null || true)"

        if [ -n "$agent_pid" ] && [ "$agent_pid" -ne 0 ] 2>/dev/null; then
          running_bin="$(${pkgs.coreutils}/bin/readlink -f "/proc/$agent_pid/exe" 2>/dev/null || true)"

          if [ -n "$running_bin" ] && [ -n "$expected_bin_resolved" ] && [ "$expected_bin_resolved" != "$running_bin" ]; then
            echo "restart-cachix-agent: Binary changed from $running_bin to $expected_bin_resolved. Restarting."
            ${pkgs.systemd}/bin/systemctl restart cachix-agent.service
          else
            echo "restart-cachix-agent: Binary is up-to-date ($running_bin)."
          fi
        else
          echo "restart-cachix-agent: Agent is not running. No action needed."
        fi
      '';
    };

    system.build.deployHealthRollbackScript = rollbackScript;
    system.extraDependencies = [rollbackScript];
  };

  perSystem = {system, ...}: {
    checks =
      lib.mapAttrs'
      (name: cfg:
        lib.nameValuePair
        "rollbackScript-${name}"
        cfg.config.system.build.deployHealthRollbackScript)
      (lib.filterAttrs
        (_: cfg:
          cfg.pkgs.stdenv.hostPlatform.system
          == system
          && (cfg.config.services.cachix-agent.enable or false))
        (self.nixosConfigurations or {}));
  };
}
