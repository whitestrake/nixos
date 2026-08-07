{
  den.aspects.docker-zfs-snapshots.nixos = {
    config,
    lib,
    ...
  }:
    lib.mkIf
    (
      config.fileSystems ? "/opt/docker"
      && config.fileSystems."/opt/docker".fsType == "zfs"
    )
    {
      services.sanoid = {
        enable = true;
        templates.docker-state = {
          hourly = 24;
          daily = 7;
          monthly = 2;
          autosnap = true;
          autoprune = true;
        };
        datasets.${config.fileSystems."/opt/docker".device}.use_template = ["docker-state"];
      };

      den.deploy.health = {
        requiredSystemdUnits = ["sanoid.timer"];
        requiredCommands.sanoid-datasets = "${lib.getExe config.boot.zfs.package} list ${lib.escapeShellArgs (lib.attrNames config.services.sanoid.datasets)} >/dev/null";
      };
    };
}
