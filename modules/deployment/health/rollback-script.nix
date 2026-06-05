{
  self,
  lib,
  ...
}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    # Get all NixOS configurations on this system that have the Cachix Agent enabled
    nixosHostsOnSystem = lib.filterAttrs (
      name: cfg:
        cfg.pkgs.stdenv.hostPlatform.system
        == system
        && cfg.config.services.cachix-agent.enable or false
    ) (self.nixosConfigurations or {});

    # Function to generate health check commands for a single host
    mkHostChecks = name: let
      cfg = self.nixosConfigurations.${name}.config;
      healthCfg = cfg.den.deploy.health;

      # systemd unit checks (budget: 5 attempts, 1s delay)
      unitChecks =
        map (unit: ''
          check_with_retry "systemd-unit-${unit}" 5 1 check_systemd_unit "${unit}"
        '')
        healthCfg.requiredSystemdUnits;

      # custom command checks (budget: global default)
      commandChecks =
        lib.mapAttrsToList (cmdName: cmd: ''
          check_with_retry "command-${cmdName}" - - check_command ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg cmd}
        '')
        healthCfg.requiredCommands;

      # HTTP endpoint checks (budget: 10 attempts, 3s delay)
      httpChecks =
        lib.mapAttrsToList (epName: ep: ''
          check_with_retry "http-${epName}" 10 3 check_http_endpoint "${epName}" "${ep.url}" "${toString ep.expectStatus}"
        '')
        healthCfg.requiredHttpEndpoints;

      # rsyncd checks (if enabled on this host)
      # systemd service budget: 5 attempts, 1s delay
      # socket check budget: 15 attempts, 2s delay
      # NOTE: We intentionally check rsync.service instead of rsyncd.service because
      # this repository uses the non-socket-activated rsyncd configuration in NixOS.
      rsyncdChecks = lib.optionalString (cfg.services.rsyncd.enable or false) ''
        check_with_retry "systemd-unit-rsync.service" 5 1 check_systemd_unit "rsync.service"
        check_with_retry "rsyncd-socket" 15 2 check_command ${pkgs.coreutils}/bin/timeout 5 ${pkgs.bash}/bin/bash -c '</dev/tcp/${name}.fell-monitor.ts.net/873'
      '';

      # extra check script
      extraCheck = lib.optionalString (healthCfg.extraCheckScript != "") ''
        log "Running extra check script for ${name}..."
        ${healthCfg.extraCheckScript}
      '';
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
      # Safely access den.deploy.health options
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

    # Generate the rollback script text
    rollbackScriptText = ''
      #!/usr/bin/env bash
      # Auto-generated deploy rollback script for system ${system}
      set -euo pipefail

      log() { echo "deploy-health: $*" >&2; }
      fail() { log "FAIL: $*"; exit 1; }

      check_systemd_unit() {
        local unit="$1"
        ${pkgs.systemd}/bin/systemctl is-active --quiet "$unit"
      }

      check_command() {
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
          if "$@"; then
            log "Check '$name' PASSED"
            return 0
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

      log "Starting deploy health checks on $host (settling delay: ''${DEPLOY_HEALTH_SETTLE_SECONDS:-10}s)..."
      sleep "''${DEPLOY_HEALTH_SETTLE_SECONDS:-10}"

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
