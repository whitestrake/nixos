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
          coreAddress = "https://komodo.whitestrake.net";
          connectAs = config.networking.hostName;
          onboardingKeyFile = config.sops.secrets.komodoOnboardingKey.path;
        };
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
