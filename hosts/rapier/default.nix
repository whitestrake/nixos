{
  inputs,
  config,
  lib,
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
    ../../users/mediaserver.nix
  ];

  system.stateVersion = "25.05";

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

  sops.secrets."smbCredentials/rapier@tempus" = {};
  fileSystems = let
    credentials = config.sops.secrets."smbCredentials/rapier@tempus".path;
    uid = config.users.users.mediaserver.uid;
  in {
    "/mnt/media" = lib.mkCifs {
      device = "//tempus.lab.whitestrake.net/Media";
      inherit uid credentials;
    };
    "/mnt/plex" = lib.mkCifs {
      device = "//tempus.lab.whitestrake.net/Plex";
      inherit uid credentials;
    };
    "/mnt/jellyfin" = lib.mkCifs {
      device = "//tempus.lab.whitestrake.net/Jellyfin";
      inherit uid credentials;
    };
  };
}
