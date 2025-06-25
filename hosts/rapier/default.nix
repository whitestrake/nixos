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

  # Hostname and TZ
  networking.hostName = "rapier";
  networking.domain = "lab.whitestrake.net";
  time.timeZone = "Australia/Brisbane";
}
