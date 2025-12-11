{
  inputs,
  config,
  pkgs,
  ...
}: {
  imports = [
    inputs.disko.nixosModules.disko
    (import ./disko-configuration.nix {
      disks = ["/dev/vda"];
      zpoolName = config.networking.hostName;
    })

    ./hardware-configuration.nix
    ../../extra/i915-sriov.nix

    ../../extra/docker.nix
    ../../secrets
  ];

  system.stateVersion = "25.05";
  environment.systemPackages = with pkgs; [
    sops
    age
    deploy-rs
    nil
    alejandra
  ];

  # QEMU guest agent
  services.qemuGuest.enable = true;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.zfs.devNodes = "/dev/disk/by-partuuid";

  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 2097152;
  };

  # Hostname and TZ
  networking.hostName = "rapier";
  networking.domain = "lab.whitestrake.net";
  networking.hostId = "3ae03bc7";
  time.timeZone = "Australia/Brisbane";

  # mediaserver user
  users.users.mediaserver.isSystemUser = true;
  users.users.mediaserver.group = "mediaserver";
  users.users.mediaserver.uid = 1001;
  users.groups.mediaserver.gid = 1001;

  sops.secrets."smbCredentials/rapier@tempus" = {};
  fileSystems = let
    mkCifs = {
      device,
      uid,
      gid ? uid,
      credentials ? config.sops.secrets."smbCredentials/rapier@tempus".path,
    }: {
      device = device;
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
        "credentials=${credentials}"
        "uid=${toString uid}"
        "gid=${toString gid}"
      ];
    };
  in {
    "/mnt/media" = mkCifs {
      device = "//tempus.lab.whitestrake.net/Media";
      uid = config.users.users.mediaserver.uid;
    };
    "/mnt/plex" = mkCifs {
      device = "//tempus.lab.whitestrake.net/Plex";
      uid = config.users.users.mediaserver.uid;
    };
    "/mnt/jellyfin" = mkCifs {
      device = "//tempus.lab.whitestrake.net/Jellyfin";
      uid = config.users.users.mediaserver.uid;
    };
  };
}
