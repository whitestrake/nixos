{
  lib,
  pkgs,
  modulesPath,
  config,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
    ../../users/whitestrake

    ../../extra/vaapi.nix
    ../../extra/docker.nix
    ../../extra/sensu.nix
    ../../extra/netdata.nix
    ../../extra/alloy.nix
    ../../extra/beszel.nix
    ../../secrets
  ];
  system.stateVersion = "23.11";

  networking.hostName = "brutus";
  networking.domain = "lab.whitestrake.net";
  time.timeZone = "Australia/Brisbane";

  # Fix Alloy collector ID
  systemd.services.alloy.environment.GCLOUD_FM_COLLECTOR_ID = lib.mkForce "brutus";

  # Tailscale networking
  services.tailscale.enable = true;
  services.tailscale.package = pkgs.unstable.tailscale;

  # www-data user
  users.users.www-data.isSystemUser = true;
  users.users.www-data.group = "www-data";
  users.users.www-data.uid = 33;
  users.groups.www-data.gid = 33;

  # mediaserver user
  users.users.mediaserver.isSystemUser = true;
  users.users.mediaserver.group = "mediaserver";
  users.users.mediaserver.uid = 77;
  users.groups.mediaserver.gid = 77;

  # Filesystem mounts from Triton
  sops.secrets."smbCredentials/brutus@triton" = {};
  environment.systemPackages = [pkgs.cifs-utils];
  fileSystems = let
    triton = {
      fsType = "cifs";
      noCheck = true;
      options = [
        "soft"
        "nofail"
        "_netdev"
        "x-systemd.automount"
        "x-systemd.idle-timeout=60"
        "x-systemd.mount-timeout=5"
        "x-systemd.device-timeout=5"
        "file_mode=0660"
        "dir_mode=0770"
        "credentials=${config.sops.secrets."smbCredentials/brutus@triton".path}"
      ];
    };
  in {
    "/mnt/media" =
      triton
      // {
        device = "//triton.lab.whitestrake.net/Media";
        options = triton.options ++ ["uid=77" "gid=77"];
      };
  };
}
