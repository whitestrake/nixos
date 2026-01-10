{
  config,
  inputs,
  pkgs,
  myLib,
  ...
}: {
  imports = [
    inputs.vscode-server.nixosModules.default
    ./hardware-configuration.nix
    ../../extra/i915-sriov.nix

    ../../extra/docker.nix
    ../../secrets
    ../../users/mediaserver.nix
    ../../users/builder.nix
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

  services.vscode-server.enable = true;
  environment.systemPackages = with pkgs; [
    sops
    age
    deploy-rs
    nix-update
    nil
    alejandra
    cifs-utils
  ];
  environment.shellAliases.deploy-rs-async = let
    system = pkgs.stdenv.hostPlatform.system;
    deploy-rs-async = inputs.deploy-rs-async.packages.${system}.deploy-rs;
  in "${deploy-rs-async}/bin/deploy --remote-build";

  # Filesystem mounts from Tempus
  sops.secrets."smbCredentials/pascal@tempus" = {};
  fileSystems = let
    credentials = config.sops.secrets."smbCredentials/pascal@tempus".path;
  in {
    "/mnt/media" = myLib.mkCifs {
      device = "//tempus.lab.whitestrake.net/Media";
      uid = config.users.users.mediaserver.uid;
      inherit credentials;
    };
    "/mnt/nextcloud" = myLib.mkCifs {
      device = "//tempus.lab.whitestrake.net/Nextcloud";
      uid = 33;
      inherit credentials;
    };
    "/mnt/downloads" = {
      device = "/dev/disk/by-label/downloads";
      fsType = "ext4";
    };
  };
}
