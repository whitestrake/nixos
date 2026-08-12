{inputs, ...}: {
  flake-file.inputs.nix-amp = {
    url = "github:whitestrake/nix-amp";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.aspects.amp.nixos = {config, ...}: {
    imports = [inputs.nix-amp.nixosModules.default];

    sops.secrets = {
      AmpAdminPassword = {};
      AmpLicenseKey = {};
    };

    virtualisation.podman.enable = true;

    den.deploy.health.requiredSystemdUnits = [
      "ampinstmgr.service"
      "ampads-reconcile.service"
      "ampfirewall-bridge.service"
    ];

    services.amp = {
      enable = true;

      ads = {
        bootstrap = {
          adminPasswordFile = config.sops.secrets.AmpAdminPassword.path;
          licenceKeyFile = config.sops.secrets.AmpLicenseKey.path;
        };

        settings = {
          createInContainers = true;
          containerManager = "Automatic";
          useHostNetworkingForNewContainers = false;
          autoStartInstances = true;
          excludeNewInstancesFromFirewall = false;
          defaultAuthServerUrl = "http://host.containers.internal:8080/";
          propagateAuthServer = true;
          enablePassthruAuth = true;
          defaultInstanceBindAddress = "0.0.0.0";
          defaultApplicationBindAddress = "0.0.0.0";
          allowAnalytics = false;
          autoReportFatalExceptions = false;
          enhancedLicenceReporting = false;
        };
      };
    };
  };
}
