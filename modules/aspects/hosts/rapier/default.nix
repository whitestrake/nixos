{
  den,
  inputs,
  ...
}: {
  flake-file.inputs.disko = {
    url = "github:nix-community/disko/latest";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.aspects.rapier = {
    includes = [
      den.aspects.lab-server
      den.aspects.docker
      den.aspects.i915-sriov
      den.aspects.user-mediaserver
      den.aspects.cifs-client
    ];

    nixos = {
      config,
      lib,
      ...
    }: {
      imports = [
        inputs.disko.nixosModules.disko
        (import ./_disko.nix {
          disks = ["/dev/vda"];
          zpoolName = config.networking.hostName;
        })
        ./_hardware.nix
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
      networking.hostId = "3ae03bc7";

      sops.secrets."smbCredentials/rapier@tempus" = {};
      storage.cifsMounts = let
        credentials = config.sops.secrets."smbCredentials/rapier@tempus".path;
        uid = config.users.users.mediaserver.uid;
      in {
        "/mnt/media" = {
          device = "//tempus.lab.whitestrake.net/Media";
          inherit uid credentials;
        };
        "/mnt/plex" = {
          device = "//tempus.lab.whitestrake.net/Plex";
          inherit uid credentials;
        };
        "/mnt/jellyfin" = {
          device = "//tempus.lab.whitestrake.net/Jellyfin";
          inherit uid credentials;
        };
      };
    };
  };
}
