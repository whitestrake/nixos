{pkgs, ...}: {
  imports = [
    ./hardware-configuration.nix
    ../../users/whitestrake
    ../common.nix

    ../../extra/docker.nix
    ../../extra/sensu.nix
    ../../extra/netdata.nix
    ../../secrets
  ];
  system.stateVersion = "24.05";

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # QEMU guest agent
  services.qemuGuest.enable = true;

  # Hostname and TZ
  networking.hostName = "pascal";
  networking.domain = "lab.whitestrake.net";
  time.timeZone = "Australia/Brisbane";

  # Networking
  services.tailscale.enable = true; # Tailscale networking
  services.tailscale.package = pkgs.unstable.tailscale;
}
