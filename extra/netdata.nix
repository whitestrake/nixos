{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [../secrets];
  sops.secrets."netdata/claim.txt".owner =
    config.systemd.services.netdata.serviceConfig.User;

  systemd.services.netdata.serviceConfig.SupplementaryGroups =
    lib.optional config.virtualisation.docker.enable "docker"
    ++ lib.optional config.virtualisation.podman.enable "podman";

  services.netdata = {
    enable = true;
    package = pkgs.unstable.netdataCloud;
    claimTokenFile = config.sops.secrets."netdata/claim.txt".path;
    config.ml.enabled = "yes";
  };
}
