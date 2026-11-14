{den, ...}: {
  den.aspects.orthus = {
    includes = [
      den.aspects.server
      den.aspects.docker
      den.aspects.komodo-core
      den.aspects.crowdsec.edge
    ];

    nixos = {lib, ...}: {
      imports = [
        ./_hardware.nix
      ];
      system.stateVersion = "24.11";

      boot.loader.grub.enable = true;
      boot.loader.grub.device = "/dev/vda";

      # Ahead of the move to a ZFS root: the running system needs ZFS support,
      # and the pool records the hostId that last imported it.
      boot.supportedFilesystems.zfs = true;
      networking.hostId = "a6a42606";
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
      };

      # https://github.com/NixOS/nixpkgs/issues/180175#issuecomment-1502421373
      systemd.services.NetworkManager-wait-online.enable = lib.mkForce false;
      systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;

      # caddy-docker-proxy sites log access as JSON on stdout (PRIORITY=6);
      # Caddy's own log stays on stderr. -o cat hands the parser the bare JSON.
      services.crowdsec = {
        hub.collections = ["crowdsecurity/caddy"];
        settings.acquisitions = [
          {
            source = "journalctl";
            journalctl_filter = ["-o" "cat" "CONTAINER_NAME=orthus-caddy-1" "PRIORITY=6"];
            labels.type = "caddy";
          }
        ];
      };
    };
  };
}
