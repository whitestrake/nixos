{
  den,
  inputs,
  ...
}: {
  den.aspects.onager = {
    includes = [
      den.aspects.server.lab
      den.aspects.docker
      den.aspects.dev-tools
    ];

    backup.source.hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICjab5VQJMOExAY9c4raC+tL9S5hYoGs/7cxUpG88oyn";

    nixos = {config, ...}: {
      imports = [
        inputs.disko.nixosModules.disko
        (import ../_disko.uefi.default.nix {
          disks = ["/dev/sda"];
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
      boot.kernel.sysctl = {
        "vm.swappiness" = 10;
      };

      services.qemuGuest.enable = true;
      services.zfs.autoScrub.enable = true;

      zramSwap.enable = true;

      networking.hostId = "79cdc322";
    };
  };
}
