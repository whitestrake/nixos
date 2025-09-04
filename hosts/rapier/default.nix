{inputs, ...}: {
  imports = [
    inputs.disko.nixosModules.disko
    ./disko-configuration.nix
    ./hardware-configuration.nix
    ../../users/whitestrake

    ../../extra/docker.nix
    ../../extra/beszel.nix
    ../../extra/komodo.nix
    ../../secrets
  ];
  system.stateVersion = "24.11";

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.zfs.devNodes = "/dev/disk/by-uuid";

  # Hostname and TZ
  networking.hostName = "rapier";
  networking.domain = "whitestrake.net";
  networking.hostId = "3ae03bc7";
  time.timeZone = "Australia/Brisbane";
}
