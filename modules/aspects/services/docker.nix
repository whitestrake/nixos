{den, ...}: {
  den.aspects.docker = {
    includes = [
      den.aspects.rsyncd-docker-export
      den.aspects.komodo-periphery
    ];

    nixos = {
      config,
      lib,
      ...
    }: {
      # Docker Service
      virtualisation.docker.enable = true;
      virtualisation.docker.autoPrune.enable = true;
      virtualisation.docker.liveRestore = false;
      systemd.tmpfiles.rules = ["d /opt/docker 0770 nobody docker"];

      # Keep dhcpcd off Docker's interfaces. Otherwise it runs IPv4LL and IPv6
      # router solicitation on every container veth, and a burst of container
      # restarts overflows its route socket and crashes it (dhcpcd 10.3.1
      # SEGV in ipv6nd_expire). tailscale0 is already denied by the Tailscale
      # module.
      networking.dhcpcd.denyInterfaces = ["veth*" "docker*" "br-*"];
      den.deploy.health = {
        requiredSystemdUnits = ["docker.service"];
        requiredCommands.docker = "${lib.getExe config.virtualisation.docker.package} info";
      };

      environment.shellAliases = {
        dps = "docker ps -as --format 'table {{.Names}}\t{{.Status}}\t{{.Size}}'";
        dc = "docker compose";
        dcl = "dc logs -f --tail 20";
      };
    };
  };
}
