{config, ...}: {
  imports = [./komodo.nix];
  virtualisation.docker.enable = true;
  virtualisation.docker.autoPrune.enable = true;
  systemd.tmpfiles.rules = ["d /opt/docker 0770 nobody docker"];

  environment.shellAliases = {
    # Docker specific aliases
    dps = "docker ps -as --format 'table {{.Names}}\t{{.Status}}\t{{.Size}}'";
    dc = "docker compose";
    dcl = "dc logs -f --tail 20";
  };

  # Allow for NAS pulls of the entire /opt/docker directory
  services.rsyncd.enable = true;
  services.rsyncd.settings = {
    globalSection.address = "${config.networking.hostName}.fell-monitor.ts.net";
    sections = {
      docker = {
        path = "/opt/docker";
        uid = "root";
        gid = "root";
        "hosts allow" = "triton.fell-monitor.ts.net,tempus.fell-monitor.ts.net";
        "read only" = true;
      };
    };
  };
  # Wait until tailscaled is up before starting rsyncd
  systemd.services.rsync.requires = ["tailscaled.service"];
  systemd.services.rsync.after = ["tailscaled.service"];
}
