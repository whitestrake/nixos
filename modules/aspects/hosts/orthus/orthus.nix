{
  den,
  inputs,
  ...
}: {
  den.aspects.orthus = {
    includes = [
      den.aspects.server
      den.aspects.docker
      den.aspects.komodo-core
      den.aspects.crowdsec.edge
      (den.aspects.backup {hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4b2cazWukt8vr4EtkRxooRBHka+0UuMI9Rz9iykwtW";})
    ];

    nixos = {
      config,
      lib,
      ...
    }: {
      imports = [
        inputs.disko.nixosModules.disko
        (import ../_disko.bios.default.nix {
          disks = ["/dev/vda"];
          zpoolName = config.networking.hostName;
        })
        ./_hardware.nix
      ];
      system.stateVersion = "24.11";

      # Use grub boot loader; disko points it at the EF02 partition on /dev/vda
      boot.loader.grub = {
        enable = true;
        copyKernels = true;
        zfsSupport = true;
      };
      boot.initrd.supportedFilesystems = ["zfs"];
      boot.zfs.devNodes = "/dev/disk/by-partuuid";
      services.zfs.autoScrub.enable = true;
      zramSwap.enable = true;

      # The pool records the hostId that last imported it; keep this fixed.
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
