{
  config,
  pkgs,
  ...
}: {
  imports = [../secrets];
  sops.secrets.netdataClaimToken = {};

  services.netdata.enable = true;
  services.netdata.package = pkgs.unstable.netdataCloud;
  services.netdata.claimTokenFile = config.sops.secrets.netdataClaimToken.path;
}
