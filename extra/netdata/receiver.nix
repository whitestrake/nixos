{
  config,
  pkgs,
  ...
}: {
  imports = [../../secrets];
  sops.secrets."netdata/receiver.conf" = {
    owner = config.systemd.services.netdata.serviceConfig.User;
  };

  services.netdata.enable = true;
  services.netdata.package = pkgs.unstable.netdataCloud;
  services.netdata.configDir = {
    "stream.conf" = config.sops.secrets."netdata/receiver.conf".path;
  };
}
