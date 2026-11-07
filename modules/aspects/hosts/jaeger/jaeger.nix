{den, ...}: {
  den.aspects.jaeger = {
    includes = [
      den.aspects.server
      den.aspects.docker
      den.aspects.crowdsec.edge
    ];

    nixos = {...}: {
      imports = [
        ./_hardware.nix
      ];
      system.stateVersion = "24.05";

      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      # Fixes sshAgentAuth for aarch64 systems
      security.sudo-rs.enable = true;

      # Pangolin's Traefik logs access lines as JSON on stdout (PRIORITY=6)
      # and its own log on stderr; -o cat hands the parser the bare JSON.
      services.crowdsec = {
        hub.collections = ["crowdsecurity/traefik"];
        localConfig.acquisitions = [
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
