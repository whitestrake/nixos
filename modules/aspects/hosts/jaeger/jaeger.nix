{
  den,
  inputs,
  ...
}: {
  den.aspects.jaeger = {
    includes = [
      den.aspects.server
      den.aspects.docker
      den.aspects.crowdsec.edge
      (den.aspects.backup {hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGf2XboT4/Cw/bVx7UJFDeWlV3gERPexJshACHRe9jcv";})
    ];

    nixos = {config, ...}: {
      imports = [
        inputs.disko.nixosModules.disko
        (import ../_disko.uefi.default.nix {
          disks = ["/dev/sda"];
          zpoolName = config.networking.hostName;
        })
        ./_hardware.nix
      ];
      system.stateVersion = "24.05";

      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      boot.zfs.devNodes = "/dev/disk/by-partuuid";
      services.zfs.autoScrub.enable = true;
      zramSwap.enable = true;

      # The pool records the hostId that last imported it; keep this fixed.
      networking.hostId = "4b90ed59";

      # Fixes sshAgentAuth for aarch64 systems
      security.sudo-rs.enable = true;

      # Pangolin's Traefik logs access lines as JSON on stdout (PRIORITY=6)
      # and its own log on stderr; -o cat hands the parser the bare JSON.
      services.crowdsec = {
        hub.collections = ["crowdsecurity/traefik"];
        settings.acquisitions = [
          {
            source = "journalctl";
            journalctl_filter = ["-o" "cat" "CONTAINER_NAME=pangolin-traefik-1" "PRIORITY=6"];
            labels.type = "traefik";
          }
        ];
      };
    };
  };
}
