{ den, inputs, ... }: {
  den.aspects.pascal = {
    includes = [
      den.provides.hostname
      den.aspects.server-base
      den.aspects.docker
      den.aspects.i915-sriov
      den.aspects.vscode-server
      den.aspects.user-builder
      den.aspects.user-mediaserver
    ];

    nixos = { config, pkgs, lib, ... }: {
      imports = [
        ./_hardware.nix
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

      environment.systemPackages = with pkgs; [
        sops
        age
        deploy-rs
        nix-update
        nix-inspect
        nil
        alejandra
        cifs-utils
      ];

      # Filesystem mounts from Tempus
      sops.secrets."smbCredentials/pascal@tempus" = {};
      fileSystems = let
        credentials = config.sops.secrets."smbCredentials/pascal@tempus".path;
      in {
        "/mnt/media" = lib.mkCifs {
          device = "//tempus.lab.whitestrake.net/Media";
          uid = config.users.users.mediaserver.uid;
          inherit credentials;
        };
        "/mnt/nextcloud" = lib.mkCifs {
          device = "//tempus.lab.whitestrake.net/Nextcloud";
          uid = 33;
          inherit credentials;
        };
        "/mnt/downloads" = {
          device = "/dev/disk/by-label/downloads";
          fsType = "ext4";
        };
      };

      networking.firewall.trustedInterfaces = [
        "netronome0" # Netronome container to agent communication
      ];
    };
  };
}
