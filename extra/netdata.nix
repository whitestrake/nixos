{
  config,
  pkgs,
  ...
}: {
  imports = [../secrets];
  sops.secrets."netdata/claim.txt" = {
    owner = config.systemd.services.netdata.serviceConfig.User;
  };

  # Add netdata user to docker group
  users.users.netdata.extraGroups = ["docker"];

  services.netdata = {
    enable = true;
    package = pkgs.unstable.netdataCloud;
    claimTokenFile = config.sops.secrets."netdata/claim.txt".path;
    config = {
      ml = {
        "enabled" = "yes";
      };
    };
  };
}
