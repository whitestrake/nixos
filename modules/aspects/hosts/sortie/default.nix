{
  den,
  inputs,
  ...
}: {
  den.aspects.sortie = {
    includes = [
      den.aspects.server-base
      den.aspects.docker
      den.aspects.i915-sriov
      den.aspects.user-mediaserver
    ];

    nixos = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [
        inputs.disko.nixosModules.disko
        (import ./_disko.nix {zpoolName = config.networking.hostName;})
        ./_hardware.nix
      ];

      system.stateVersion = "25.05";

      # QEMU guest agent
      services.qemuGuest.enable = true;

      # Use the systemd-boot boot loader
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.zfs.devNodes = "/dev/disk/by-partuuid";

      # Network hostname properties
      networking.domain = "lab.whitestrake.net";
      networking.hostId = "bffd5e86";

      # SMB mount configs
      sops.secrets."smbCredentials/sortie@tempus" = {};
      fileSystems = let
        credentials = config.sops.secrets."smbCredentials/sortie@tempus".path;
        uid = config.users.users.mediaserver.uid;
      in {
        "/mnt/media" = lib.mkCifs {
          device = "//tempus.lab.whitestrake.net/Media";
          inherit uid credentials;
        };
      };
    };
  };
}
