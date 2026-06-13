{
  self,
  lib,
  config,
  ...
}: {
  den.aspects.cachix-agent.nixos = {config, ...}: {
    sops.secrets.cachixAgentToken = {};
    services.cachix-agent = {
      enable = true;
      credentialsFile = config.sops.secrets.cachixAgentToken.path;
    };
  };

  perSystem = {
    pkgs,
    system,
    ...
  }: let
    # Cachix Deploy runs this rollback script on the host after activation.
    # Exiting non-zero marks the deployment failed and lets Cachix roll the host
    # back to the previous generation. The script is generated per Nix system and
    # dispatches at runtime by the host's kernel hostname.
    # Get all NixOS configurations on this system that have the Cachix Agent enabled.
    nixosHostsOnSystem = lib.filterAttrs (
      name: cfg:
        cfg.pkgs.stdenv.hostPlatform.system
        == system
        && cfg.config.services.cachix-agent.enable or false
    ) (self.nixosConfigurations or {});

    # Generate health checks from the evaluated host configuration. Structured
    # checks come from den.deploy.health; service-specific checks can also be
    # synthesized from other evaluated options when that is less repetitive.
    mkHostChecks = name: let
      cfg = self.nixosConfigurations.${name}.config;
      healthCfg = cfg.den.deploy.health;

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

      # systemd unit checks
      unitChecks =
        map (unit: let
          budget = unitCheckBudget unit;
        in ''
          check_or_fail "systemd unit ${unit} failed health check" "systemd-unit-${unit}" ${budget.attempts} ${budget.delay} check_systemd_unit "${unit}"
        '')
        healthCfg.requiredSystemdUnits;

      # custom command checks
      commandChecks =
        lib.mapAttrsToList (cmdName: cmd: let
          budget = commandCheckBudget cmdName;
        in ''
          check_or_fail "command ${cmdName} failed health check" "command-${cmdName}" ${budget.attempts} ${budget.delay} check_command ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg cmd}
        '')
        healthCfg.requiredCommands;

      # HTTP endpoint checks (budget: 10 attempts, 3s delay)
      httpChecks =
        lib.mapAttrsToList (epName: ep: ''
          check_or_fail "HTTP endpoint ${epName} failed health check" "http-${epName}" 10 3 check_http_endpoint "${epName}" "${ep.url}" "${toString ep.expectStatus}"
        '')
        healthCfg.requiredHttpEndpoints;

      # rsyncd checks (if enabled on this host)
      # systemd service budget: 15 attempts, 2s delay
      # socket check budget: 15 attempts, 2s delay
      rsyncdChecks = lib.optionalString (cfg.services.rsyncd.enable or false) ''
        check_or_fail "systemd unit rsync.service failed health check" "systemd-unit-rsync.service" 15 2 check_systemd_unit "rsync.service"
        check_or_fail "rsyncd socket failed health check" "rsyncd-socket" 15 2 check_command ${pkgs.coreutils}/bin/timeout 5 ${pkgs.bash}/bin/bash -c '</dev/tcp/${name}.${config.network.tailnetSuffix}/873'
      '';

      # extra check script
      extraCheck = lib.optionalString (healthCfg.extraCheckScript != "") (let
        extraScript = pkgs.writeShellScript "deploy-health-extra-${name}" healthCfg.extraCheckScript;
      in ''
        log "Running extra check script for ${name}..."
        check_or_fail "extra check script failed for ${name}" "extra-${name}" - - check_command ${extraScript}
      '');
    in ''
      ${lib.concatStringsSep "\n" unitChecks}
      ${lib.concatStringsSep "\n" commandChecks}
      ${lib.concatStringsSep "\n" httpChecks}
      ${rsyncdChecks}
      ${extraCheck}
    '';

    # Generates a case branch for a given host
    mkHostCaseBranch = name: let
      cfg = self.nixosConfigurations.${name}.config;
      isCachixManaged = cfg.services.cachix-agent.enable or false;
      # Cachix-managed hosts fail closed unless checks are enabled or the host
      # explicitly opts out with allowUnprotected. Non-Cachix hosts pass with a
      # notice because the rollback script can be shared by a whole system.
      healthCfg =
        cfg.den.deploy.health or {
          enable = false;
          allowUnprotected = false;
        };
    in
      if isCachixManaged
      then
        if healthCfg.enable
        then ''
          ${name})
            log "Running health checks for ${name}..."
            ${mkHostChecks name}
            ;;
        ''
        else if healthCfg.allowUnprotected
        then ''
          ${name})
            log "WARNING: deploy health checks are disabled for Cachix-managed host ${name} (allowUnprotected is true). Passing without checks."
            ;;
        ''
        else ''
          ${name})
            fail "ERROR: deploy health checks are disabled for Cachix-managed host ${name} and allowUnprotected is false. Rolling back deployment."
            ;;
        ''
      else ''
        ${name})
          log "Notice: ${name} is not a Cachix-managed server. Passing."
          ;;
      '';

    hostsCaseStatements = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: mkHostCaseBranch name) nixosHostsOnSystem);

    # Generate the rollback script text. The settle and retry environment
    # variables are intentionally runtime controls so deployments can be tuned
    # without rebuilding the flake when a host needs more time to converge.
    rollbackScriptText = ''
      # Auto-generated deploy rollback script for system ${system}
      set -euo pipefail

      deploy_start_epoch="$(${pkgs.coreutils}/bin/date +%s)"
      diagnostics_collected=0

      command_timeout_seconds="''${DEPLOY_HEALTH_COMMAND_TIMEOUT_SECONDS:-10}"
      systemctl_timeout_seconds="''${DEPLOY_HEALTH_SYSTEMCTL_TIMEOUT_SECONDS:-5}"
      diagnostic_timeout_seconds="''${DEPLOY_HEALTH_DIAGNOSTIC_TIMEOUT_SECONDS:-15}"
      diagnostic_journal_lines="''${DEPLOY_HEALTH_DIAGNOSTIC_JOURNAL_LINES:-300}"

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

      check_http_endpoint() {
        local ep_name="$1"
        local url="$2"
        local expected_status="$3"

        local status
        if ! status=$(${pkgs.curl}/bin/curl --silent --show-error --max-time 10 --write-out '%{http_code}' --output /dev/null "$url"); then
          log "HTTP check '$ep_name' failed: curl execution failed"
          return 1
        fi

        status="''${status:-0}"
        if [ "$status" -ne "$expected_status" ]; then
          log "HTTP check '$ep_name' failed: expected status $expected_status, got $status"
          return 1
        fi
        return 0
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

      host="$(${pkgs.coreutils}/bin/cat /proc/sys/kernel/hostname)"

      log "Starting deploy health checks on $host..."


      case "$host" in
        ${hostsCaseStatements}
        *)
          fail "no deploy health checks generated for host: $host"
          ;;
      esac

      log "all checks passed for $host"
    '';

    isLinux = lib.strings.hasSuffix "-linux" system;
  in {
    packages = lib.optionalAttrs isLinux {
      # The hostname-dispatching rollback script for this system (outputs a file directly in store)
      deploy-health-rollback-script = pkgs.writeShellScript "deploy-health-rollback-script" rollbackScriptText;
    };

    checks = lib.optionalAttrs isLinux {
      # Flake check that validates the syntax and shell quality of the generated script
      validate-deploy-health-rollback-script =
        pkgs.runCommand "validate-deploy-health-rollback-script" {
          nativeBuildInputs = [pkgs.shellcheck];
        } ''
          script="${self.packages.${system}.deploy-health-rollback-script}"

          echo "Checking syntax with bash -n..."
          bash -n "$script"

          echo "Checking script style with shellcheck..."
          shellcheck -s bash "$script"

          echo "Checking for bare hostname command regression..."
          if grep -E '\$\([[:space:]]*hostname[[:space:]]*\)|(^|[;&|[:space:]])hostname([[:space:]]|$)' "$script"; then
            echo "ERROR: generated rollback script contains a bare hostname invocation." >&2
            exit 1
          fi

          echo "Checking for missing host command regression..."
          if grep -E '/bin/host([[:space:]]|$)' "$script"; then
            echo "ERROR: generated rollback script contains a reference to /bin/host." >&2
            exit 1
          fi

          echo "Verifying presence of store-qualified hostname retrieval..."
          grep -F '${pkgs.coreutils}/bin/cat /proc/sys/kernel/hostname' "$script"

          touch $out
        '';
    };
  };
}
