{
  config,
  inputs,
  pkgs,
  ...
}: {
  imports = [
    inputs.vscode-server.nixosModules.default
    ./hardware-configuration.nix
    ../../users/whitestrake

    ../../extra/docker.nix
    ../../extra/sensu.nix
    ../../extra/alloy.nix
    ../../extra/beszel.nix
    ../../secrets
  ];
  system.stateVersion = "24.05";

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # QEMU guest agent
  services.qemuGuest.enable = true;

  # Hostname and TZ
  networking.hostName = "pascal";
  networking.domain = "lab.whitestrake.net";
  time.timeZone = "Australia/Brisbane";

  services.vscode-server.enable = true;
  environment.systemPackages = with pkgs; [
    sops
    age
    deploy-rs
    nil
    alejandra
    cifs-utils
  ];

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
  sops.secrets."smbCredentials/pascal@tempus" = {};
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
        "credentials=${config.sops.secrets."smbCredentials/pascal@tempus".path}"
      ];
    };
  in {
    "/mnt/media" =
      tempus
      // {
        device = "//tempus.lab.whitestrake.net/Media";
        options = tempus.options ++ ["uid=1001" "gid=1001"];
      };
    "/mnt/nextcloud" =
      tempus
      // {
        device = "//tempus.lab.whitestrake.net/Nextcloud";
        options = tempus.options ++ ["uid=33" "gid=33"];
      };
    "/mnt/downloads" = {
      device = "/dev/disk/by-label/downloads";
      fsType = "ext4";
    };
  };
}
