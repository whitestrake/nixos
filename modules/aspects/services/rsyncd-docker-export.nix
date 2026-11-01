{...}: {
  den.aspects.rsyncd-docker-export = {
    nixos = {
      host,
      pkgs,
      ...
    }: {
      # Allow for NAS pulls of the entire /opt/docker directory via rsyncd
      services.rsyncd.enable = true;
      services.rsyncd.settings = {
        globalSection.address = "${host.name}.${host.tailnetSuffix}";
        sections = {
          docker = {
            path = "/opt/docker";
            uid = "root";
            gid = "root";
            "read only" = true;
            "hosts allow" = "triton.${host.tailnetSuffix},tempus.${host.tailnetSuffix}";
          };
        };
      };
      systemd.services.rsync = {
        requires = ["tailscaled.service"];
        after = ["tailscaled.service"];
        # rsyncd binds to its tailnet name, which MagicDNS can take a moment
        # to resolve after tailscaled reports ready (seen on a cold boot).
        serviceConfig = {
          ExecStartPre = "${pkgs.coreutils}/bin/timeout 60 ${pkgs.bash}/bin/bash -c 'until ${pkgs.getent}/bin/getent hosts ${host.name}.${host.tailnetSuffix} >/dev/null; do sleep 1; done'";
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
      den.deploy.health = {
        requiredSystemdUnits = ["rsync.service"];
        requiredCommands.rsyncd-socket = "${pkgs.coreutils}/bin/timeout 5 ${pkgs.bash}/bin/bash -c '</dev/tcp/${host.name}.${host.tailnetSuffix}/873'";
      };
    };
  };
}
