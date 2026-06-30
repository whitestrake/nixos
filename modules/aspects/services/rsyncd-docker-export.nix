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
      systemd.services.rsync.requires = ["tailscaled.service"];
      systemd.services.rsync.after = ["tailscaled.service"];
      den.deploy.health = {
        requiredSystemdUnits = ["rsync.service"];
        requiredCommands.rsyncd-socket = "${pkgs.coreutils}/bin/timeout 5 ${pkgs.bash}/bin/bash -c '</dev/tcp/${host.name}.${host.tailnetSuffix}/873'";
      };
    };
  };
}
