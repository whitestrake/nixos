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
  users.users.mediaserver.uid = 1001;
  users.groups.mediaserver.gid = 1001;

  # Filesystem mounts from Tempus
  sops.secrets."smbCredentials/brutus@tempus" = {};
  environment.systemPackages = [pkgs.cifs-utils];
  fileSystems = let
    tempus = {
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
        "credentials=${config.sops.secrets."smbCredentials/brutus@tempus".path}"
      ];
    };
  in {
    "/mnt/media" =
      tempus
      // {
        device = "//tempus.lab.whitestrake.net/Media";
        options = tempus.options ++ ["uid=1001" "gid=1001"];
      };
    "/mnt/plex" =
      tempus
      // {
        device = "//tempus.lab.whitestrake.net/Plex";
        options = tempus.options ++ ["uid=1001" "gid=1001"];
      };
    "/mnt/jellyfin" =
      tempus
      // {
        device = "//tempus.lab.whitestrake.net/Jellyfin";
        options = tempus.options ++ ["uid=1001" "gid=1001"];
      };
  };

  # Allow for NAS pulls of the entire /opt/docker directory
  sops.secrets.hostsEnv = {};
  systemd.services.rsync.serviceConfig.EnvironmentFile = config.sops.secrets.hostsEnv.path;
  services.rsyncd.enable = true;
  services.rsyncd.settings = {
    global.address = "%HOST_BRUTUS%";
    docker = {
      path = "/opt/docker";
      uid = "root";
      gid = "root";
      "hosts allow" = "%HOST_TRITON%";
      "read only" = true;
    };
  };
}
