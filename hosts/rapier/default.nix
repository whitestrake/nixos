{
  inputs,
  config,
  pkgs,
  ...
}: {
  imports = [
    inputs.i915-sriov.nixosModules.default
    inputs.disko.nixosModules.disko
    (import ./disko-configuration.nix {
      disks = ["/dev/vda"];
      zpoolName = config.networking.hostName;
    })
    ./hardware-configuration.nix
    ../../users/whitestrake

    ../../extra/docker.nix
    ../../extra/beszel.nix
    ../../extra/check_mk.nix
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

    libva-utils
    intel-gpu-tools
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.zfs.devNodes = "/dev/disk/by-partuuid";

  # i915 SR-IOV driver
  boot.extraModulePackages = [pkgs.i915-sriov];
  boot.kernelParams = ["intel_iommu=on" "i915.enable_guc=3" "module_blacklist=xe"];

  # Hostname and TZ
  networking.hostName = "rapier";
  networking.domain = "lab.whitestrake.net";
  networking.hostId = "3ae03bc7";
  time.timeZone = "Australia/Brisbane";
}
