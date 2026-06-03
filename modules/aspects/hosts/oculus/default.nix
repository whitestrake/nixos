{
  den,
  inputs,
  ...
}: {
  den.aspects.oculus = {
    includes = [
      den.aspects.server-base
      den.aspects.docker
    ];

    nixos = {config, ...}: {
      imports = [
        inputs.disko.nixosModules.disko
        (import ./_disko.nix {
          disks = ["/dev/vda"];
          zpoolName = config.networking.hostName;
        })
        ./_hardware.nix
      ];
      system.stateVersion = "25.11";

      # Use grub boot loader
      boot.loader.grub = {
        enable = true;
        copyKernels = true;
        zfsSupport = true;
      };
      boot.initrd.supportedFilesystems = ["zfs"];
      boot.zfs.devNodes = "/dev/disk/by-partuuid";
      services.zfs.autoScrub.enable = true;

      # Hostname and TZ
      networking.domain = "whitestrake.net";
      networking.hostId = "464b2c8a";
    };
  };
}
