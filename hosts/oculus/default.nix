{
  inputs,
  config,
  ...
}: {
  imports = [
    inputs.disko.nixosModules.disko
    (import ./disko-configuration.nix {
      disks = ["/dev/vda"];
      zpoolName = config.networking.hostName;
    })

    ./hardware-configuration.nix
    ../../extra/docker.nix
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
  networking.hostName = "oculus";
  networking.domain = "whitestrake.net";
  networking.hostId = "464b2c8a";
  time.timeZone = "Australia/Brisbane";
}
