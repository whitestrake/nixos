{den, ...}: {
  den.aspects.docker = {
    includes = [
      den.aspects.rsyncd-docker-export
      den.aspects.komodo-periphery
    ];

    nixos = {pkgs, ...}: {
      # Docker Service
      virtualisation.docker.enable = true;
      virtualisation.docker.package = pkgs.docker_29;
      virtualisation.docker.autoPrune.enable = true;
      virtualisation.docker.liveRestore = false;
      systemd.tmpfiles.rules = ["d /opt/docker 0770 nobody docker"];

      environment.shellAliases = {
        dps = "docker ps -as --format 'table {{.Names}}\t{{.Status}}\t{{.Size}}'";
        dc = "docker compose";
        dcl = "dc logs -f --tail 20";
      };
    };
  };
}
