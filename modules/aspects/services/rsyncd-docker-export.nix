{...} @ flake: {
  den.aspects.rsyncd-docker-export = {
    nixos = {host, ...}: {
      # Allow for NAS pulls of the entire /opt/docker directory via rsyncd
      services.rsyncd.enable = true;
      services.rsyncd.settings = with flake.config.network; {
        globalSection.address = "${host.name}.${tailnetSuffix}";
        sections = {
          docker = {
            path = "/opt/docker";
            uid = "root";
            gid = "root";
            "read only" = true;
            "hosts allow" = "triton.${tailnetSuffix},tempus.${tailnetSuffix}";
          };
        };
      };
      systemd.services.rsync.requires = ["tailscaled.service"];
      systemd.services.rsync.after = ["tailscaled.service"];
    };
  };
}
