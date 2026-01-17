{
  inputs,
  config,
  pkgs,
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
    ../../extra/attic.nix
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

  # TrueNAS user
  users.users.truenas = {
    isNormalUser = true;
    openssh.authorizedKeys.keys = [
      "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCvADU7QJ2eCkE93nKS+jWdlwUITpzbCb1sX0p3LIL2UqJnUDTghEMpZqbX0Zf3NL6HfY9sVVe3jFtJ4qV5pQ2HfAj2A2Y0gGAIC4d9VhimHEnbDwRoUmWedjQCJeMsbslSWyIYXqlun3R89q8XMllwENPjmZ1Llj2L1Y7ICueThPlA5GFw7EYxshixQ8ApJtx+CvI8/S0IYYjL83ZyyE51xpJWqiKU8rjbF35h8Fw5qGEvnWSluc/vybhp4jBy9Yq5g6rmHJ4jL9cTe9mg7q8MActASp8PGju0BCRDXCHcvS1NblqxbFdAXwQv4S4H8H0ebsUmVJbUfkP+GGMH4dczcL8EZjtvQTvoV/vRab/y/sAbluNFvfAXWtb/kT5T2WnjilJe3yO+ZX0gPWl9fZ8xiw/hzi5kGSZmb+zArzO0qUwS9KZNWPQvvNqsCOKC0qmtkCl6BvZwprjSlDCTyUrUdPUoy0tr2iHI3Bdflig/RPVfnKVmPDpHMEVxdeQ25bs="
    ];
  };
  security.sudo.extraRules = [
    {
      users = ["truenas"];
      commands = [
        {
          command = "/run/current-system/sw/bin/zfs";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];
  environment.systemPackages = with pkgs; [
    # provide pigz, plzip, lz4c commands for zettarepl
    pigz
    plzip
    (lz4.overrideAttrs (old: {
      postInstall =
        (old.postInstall or "")
        + ''
          ln -s lz4 $out/bin/lz4c
        '';
    }))
  ];
}
