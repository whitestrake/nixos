{den, ...}: {
  den.aspects.server-base = {
    includes = [
      den.aspects.linux-base
      den.aspects.monitoring
      den.aspects.cachix-agent
      den.aspects.deploy-health
    ];

    nixos = {
      config,
      pkgs,
      lib,
      ...
    }: {
      den.deploy.health = {
        enable = lib.mkDefault true;
        allowUnprotected = lib.mkDefault false;
        requiredSystemdUnits = [
          "sshd.service"
          "tailscaled.service"
          "cachix-agent.service"
        ];
        requiredCommands = {
          dns = "${pkgs.dnsutils}/bin/host whitestrake.net";
          tailscale = "${pkgs.tailscale}/bin/tailscale status --peers=false";
        };
      };

      sops.secrets.tailscaleOauthKey = {};
      services.tailscale = {
        authKeyFile = config.sops.secrets.tailscaleOauthKey.path;
        useRoutingFeatures = "both";
        authKeyParameters.ephemeral = false;
        extraUpFlags = ["--advertise-tags=tag:server"];
      };

      systemd.services.tailscaled.serviceConfig.ExecStartPost = ''
        ${pkgs.coreutils}/bin/timeout 60s ${pkgs.bash}/bin/bash -c 'until ${config.services.tailscale.package}/bin/tailscale status --peers=false; do sleep 1; done'
      '';
    };
  };

  den.aspects.lab-server = {
    includes = [
      den.aspects.server-base
    ];

    nixos = {...}: {
      networking.domain = "lab.whitestrake.net";
    };
  };
}
