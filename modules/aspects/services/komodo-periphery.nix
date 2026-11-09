{inputs, ...}: let
  peripheryModule = "services/admin/komodo-periphery.nix";
in {
  den.aspects.komodo-periphery = {
    nixos = {
      config,
      pkgs,
      ...
    }: {
      # Disable the stable periphery module and import the unstable one
      disabledModules = [peripheryModule];
      imports = ["${inputs.nixpkgs-unstable}/nixos/modules/${peripheryModule}"];

      sops.secrets.komodoOnboardingKey = {};
      services.komodo-periphery = {
        enable = true;
        package = pkgs.unstable.komodo;
        user = "root";
        group = "root";
        outbound = {
          # Tailscale Service (svc:komodo) on the Core host. Periphery stays on
          # the tailnet; komodo.whitestrake.net (Pangolin) remains the address
          # for OIDC users and GitHub webhooks.
          coreAddress = "https://komodo.fell-monitor.ts.net";
          connectAs = config.networking.hostName;
          onboardingKeyFile = config.sops.secrets.komodoOnboardingKey.path;
        };
        # The same file Periphery pins Core's key to by default (trust on
        # first connection), named explicitly: Core's "Rotate Core Keys" only
        # updates a pin that is configured as a `file:` entry, so with the
        # implicit default a rotation would lock out every Periphery.
        auth.corePublicKeys = ["file:${config.services.komodo-periphery.rootDirectory}/keys/core.pub"];
      };
      systemd.services.komodo-periphery.path = [config.system.path];
      # The module sets ProtectHome=read-only, but Docker's build tooling writes
      # state under /root/.docker, so stacks that build an image failed to deploy.
      systemd.services.komodo-periphery.serviceConfig.ReadWritePaths = ["-/root/.docker"];

      services.networkLiveness.checks.komodo-periphery = {};
      den.deploy.health.requiredSystemdUnits = ["komodo-periphery.service"];
    };
  };
}
