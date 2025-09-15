{
  inputs,
  config,
  pkgs,
  ...
}: {
  imports = [
    inputs.disko.nixosModules.disko
    (import ./disko-configuration.nix {
      disks = ["/dev/vda"];
      zpoolName = config.networking.hostName;
    })

    ./hardware-configuration.nix
    ../../extra/i915-sriov.nix

    ../../extra/docker.nix
    ../../secrets
  ];
  system.stateVersion = "25.05";

  # QEMU guest agent
  services.qemuGuest.enable = true;

  environment.systemPackages = with pkgs; [
    sops
    age
    deploy-rs
    nil
    alejandra
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.zfs.devNodes = "/dev/disk/by-partuuid";

  # Hostname and TZ
  networking.hostName = "rapier";
  networking.domain = "lab.whitestrake.net";
  networking.hostId = "3ae03bc7";
  time.timeZone = "Australia/Brisbane";
}
