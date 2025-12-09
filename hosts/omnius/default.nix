{
  inputs,
  config,
  ...
}: {
  imports = [
    inputs.disko.nixosModules.disko
    (import ./disko-configuration.nix {
      disks = ["/dev/vda" "/dev/vdb"];
      zpoolName = config.networking.hostName;
    })

    ./hardware-configuration.nix
    ../../extra/docker.nix
    ../../secrets
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
  boot.zfs.extraPools = ["storage"];
  services.zfs.autoScrub.enable = true;

  # Hostname and TZ
  networking.hostName = "omnius";
  networking.domain = "whitestrake.net";
  networking.hostId = "4018c181";
  time.timeZone = "Australia/Brisbane";
}
