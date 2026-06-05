{
  self,
  inputs,
  lib,
  config,
  ...
}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    # Flat map all host configurations defined in den.hosts
    allHosts = lib.foldl' (acc: sys: acc // config.den.hosts.${sys}) {} (builtins.attrNames config.den.hosts);

    # Get all NixOS hosts on this system (excluding WSL)
    nixosHostsOnSystem = lib.filterAttrs (name: host: host.system == system && host.class == "nixos" && !(host.wsl.enable or false)) allHosts;

    # Function to generate health check commands for a single host
    mkHostChecks = name: let
      cfg = self.nixosConfigurations.${name}.config.den.deploy.health;

      # systemd unit checks
      unitChecks =
        map (unit: ''
          check_with_retry "systemd-unit-${unit}" "${pkgs.systemd}/bin/systemctl is-active --quiet ${unit}" || fail "Systemd unit ${unit} is not active"
        '')
        cfg.requiredSystemdUnits;

      # custom command checks
      commandChecks =
        lib.mapAttrsToList (cmdName: cmd: ''
          check_with_retry "command-${cmdName}" "${cmd}" || fail "Command check ${cmdName} failed"
        '')
        cfg.requiredCommands;

      # HTTP endpoint checks
      httpChecks =
        lib.mapAttrsToList (epName: ep: ''
          check_with_retry "http-${epName}" "STATUS=\\\$(${pkgs.curl}/bin/curl --silent --write-out '%{http_code}' --output /dev/null --max-time 10 ${lib.escapeShellArg ep.url}); [ \\\"\\\$STATUS\\\" -eq ${toString ep.expectStatus} ]" || fail "HTTP check ${epName} failed"
        '')
        cfg.requiredHttpEndpoints;

      # extra check script
      extraCheck = lib.optionalString (cfg.extraCheckScript != "") ''
        log "Running extra check script for ${name}..."
        ${cfg.extraCheckScript}
      '';
    in ''
      ${lib.concatStringsSep "\n" unitChecks}
      ${lib.concatStringsSep "\n" commandChecks}
      ${lib.concatStringsSep "\n" httpChecks}
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

      check_with_retry() {
        local name="$1"
        local cmd="$2"
        local max_attempts="''${DEPLOY_HEALTH_RETRY_ATTEMPTS:-10}"
        local delay="''${DEPLOY_HEALTH_RETRY_DELAY_SECONDS:-2}"
        local attempt=1

        log "Running check '$name'..."
        while true; do
          if eval "$cmd"; then
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

      host="$(hostname)"

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
  in {
    packages = {
      # The hostname-dispatching rollback script for this system (outputs a file directly in store)
      deploy-health-rollback-script = pkgs.writeShellScript "deploy-health-rollback-script" rollbackScriptText;
    };
  };
}
