{den, ...}: {
  den.aspects.server-base = {
    includes = [
      den.aspects.linux-base
      den.aspects.monitoring
      den.aspects.cachix-agent
    ];

    nixos = {
      config,
      pkgs,
      ...
    }: {
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
