{den, ...}: {
  den.aspects.pascal = {
    includes = [
      den.aspects.server.lab
      den.aspects.docker
      den.aspects.i915-sriov
      den.aspects.dev-tools
      den.aspects.mcp-host
    ];

    nixos = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [
        ./_hardware.nix
      ];
      system.stateVersion = "24.05";

      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      # QEMU guest agent
      services.qemuGuest.enable = true;

      environment.systemPackages = with pkgs; [
        cifs-utils
      ];

      # Filesystem mounts from Tempus
      sops.secrets."smbCredentials/pascal@tempus" = {};
      storage.cifsMounts = let
        credentials = config.sops.secrets."smbCredentials/pascal@tempus".path;
      in {
        "/mnt/media" = {
          device = "//tempus.lab.whitestrake.net/Media";
          uid = config.users.users.mediaserver.uid;
          inherit credentials;
        };
      };

      fileSystems."/mnt/downloads" = {
        device = "/dev/disk/by-label/downloads";
        fsType = "ext4";
      };

      networking.firewall.trustedInterfaces = [
        "netronome0" # Netronome container to agent communication
      ];

      # NetAlertX runs with host networking for ARP scanning, so Newt on the
      # proxy bridge reaches its web UI and GraphQL API through the host.
      networking.firewall.interfaces."br-+".allowedTCPPorts = [20211 20212];
    };
  };
}
