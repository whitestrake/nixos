# Deployment Health Checks and Rollback System

This repository implements host-local deployment health checking and automatic rollback protection for Cachix Deploy activations.

## Overview

When a new configuration is deployed via Cachix, a `rollbackScript` is executed on the target host post-activation. If the script exits with a non-zero status code, Cachix automatically rolls back the host to the previous active NixOS generation.

The rollback script is generated per Nix system (e.g. `x86_64-linux`) and dispatches by host name.

## Configuration Options

Configure host-specific checks in the host aspect or module under `den.deploy.health`:

```nix
den.deploy.health = {
  # Enable health checks for this host (defaults to false globally, enabled on server)
  enable = true;

  # Allow deployment to pass without checks if health checks are disabled.
  # For Cachix-managed NixOS hosts, if enable is false and allowUnprotected is false, 
  # the deployment will FAIL closed.
  allowUnprotected = false;

  # Systemd units that must be active (e.g. sshd, tailscaled)
  requiredSystemdUnits = [ "sshd.service" "tailscaled.service" ];

  # Commands that must return exit status 0
  requiredCommands = {
    dns = "${pkgs.dig}/bin/dig +short whitestrake.net";
  };

  # Local or remote HTTP endpoints that must return a specific status code (default: 200)
  requiredHttpEndpoints = {
    home-assistant = {
      url = "http://127.0.0.1:8123/";
      expectStatus = 200;
    };
  };

  # Extra custom shell commands to execute
  extraCheckScript = ''
    # Custom shell checks
  '';
};
```

## Retry and Settle Mechanics

To reduce false rollbacks caused by startup latency or race conditions (e.g. services starting up slowly or networking settling), the system employs two strategies:

1. **Settling Delay**: A sleep period runs at the beginning of the script to let the system settle. Defaults to `10` seconds, configurable via `DEPLOY_HEALTH_SETTLE_SECONDS`.
2. **Bounded Retries**: Every health check runs inside a retry loop. By default, it will retry up to `10` times (configurable via `DEPLOY_HEALTH_RETRY_ATTEMPTS`) with a `2`-second delay between attempts (configurable via `DEPLOY_HEALTH_RETRY_DELAY_SECONDS`) before marking the check as failed.

These parameters can be overridden on the target host by setting environment variables in the agent shell or system environment.

## Host Safety & Dispatch Behavior

To prevent accidental rollbacks or bypasses:
- **Cachix-managed NixOS servers with health checks enabled**: Run all checks. If any check fails after all retries, the script exits `1` and triggers a rollback.
- **Cachix-managed NixOS servers with health checks disabled/missing**: **Fail closed** (`exit 1`) unless `allowUnprotected = true` is explicitly configured. If `allowUnprotected = true` is set, a warning is logged and the deployment succeeds immediately.
- **WSL, Darwin, and non-Cachix hosts**: Log a notice and immediately succeed (`exit 0`).
- **Completely unknown/unmanaged hosts**: Fail closed.
