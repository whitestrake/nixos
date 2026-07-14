{den, ...}: {
  den.aspects.docker = {
    includes = [
      den.aspects.rsyncd-docker-export
      den.aspects.komodo-periphery
    ];

    nixos = {config, ...}: {
      # Docker Service
      virtualisation.docker.enable = true;
      virtualisation.docker.autoPrune.enable = true;
      virtualisation.docker.liveRestore = false;
      systemd.tmpfiles.rules = ["d /opt/docker 0770 nobody docker"];
      den.deploy.health = {
        requiredSystemdUnits = ["docker.service"];
        requiredCommands.docker = "${config.virtualisation.docker.package}/bin/docker info";
      };

      environment.shellAliases = {
        dps = "docker ps -as --format 'table {{.Names}}\t{{.Status}}\t{{.Size}}'";
        dc = "docker compose";
        dcl = "dc logs -f --tail 20";
      };
    };
  };
}
