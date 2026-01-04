{...}: {
  imports = [
    ./hardware-configuration.nix
    ../../users/builder.nix

    ../../extra/docker.nix
    ../../extra/sensu.nix
    ../../secrets
  ];
  system.stateVersion = "24.05";

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Fixes sshAgentAuth for aarch64 systems
  security.sudo-rs.enable = true;

  networking.hostName = "jaeger";
  networking.domain = "whitestrake.net";
  time.timeZone = "Australia/Brisbane";
}
