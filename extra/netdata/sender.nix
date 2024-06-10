{
  config,
  pkgs,
  ...
}: {
  imports = [../../secrets];
  sops.secrets."netdata/sender.conf" = {
    owner = config.systemd.services.netdata.serviceConfig.User;
  };

  services.netdata.enable = true;
  services.netdata.package = pkgs.unstable.netdata;
  services.netdata.configDir = {
    "stream.conf" = config.sops.secrets."netdata/sender.conf".path;
  };
}
