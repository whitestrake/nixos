{tailnetSuffix, ...}: {
  den.aspects.rsyncd-docker-export = {
    nixos = {config, ...}: {
      # Allow for NAS pulls of the entire /opt/docker directory via rsyncd
      services.rsyncd.enable = true;
      services.rsyncd.settings = {
        globalSection.address = "${config.networking.hostName}.${tailnetSuffix}";
        sections = {
          docker = {
            path = "/opt/docker";
            uid = "root";
            gid = "root";
            "hosts allow" = "triton.${tailnetSuffix},tempus.${tailnetSuffix}";
            "read only" = true;
          };
        };
      };
      systemd.services.rsync.requires = ["tailscaled.service"];
      systemd.services.rsync.after = ["tailscaled.service"];
    };
  };
}
