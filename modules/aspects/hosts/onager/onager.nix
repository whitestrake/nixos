{
  den,
  inputs,
  ...
}: {
  flake-file.inputs.disko = {
    url = "github:nix-community/disko/latest";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.aspects.onager = {
    includes = [
      den.aspects.server.lab
      den.aspects.docker
      den.aspects.dev-tools
      den.aspects.hercules
      den.aspects.hercules.prewarm
    ];

    nixos = {config, ...}: {
      imports = [
        inputs.disko.nixosModules.disko
        (import ../_disko.uefi.default.nix {
          disks = ["/dev/vda"];
          zpoolName = config.networking.hostName;
        })
        ./_hardware.nix
      ];

      system.stateVersion = "26.05";

      boot.loader.systemd-boot.enable = true;
      boot.loader.systemd-boot.editor = false;
      boot.loader.systemd-boot.configurationLimit = 20;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.zfs.devNodes = "/dev/disk/by-partuuid";
      boot.zfs.forceImportRoot = false;
      boot.kernel.sysctl = {
        "vm.swappiness" = 10;
      };

      services.qemuGuest.enable = true;
      services.zfs.autoScrub.enable = true;

      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = 50;
        priority = 100;
      };

      networking.hostId = "79cdc322";
    };
  };
}
