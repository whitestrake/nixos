{
  den,
  caches,
  mkLocalPackages,
  ...
}: let
  sharedNixSettings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@wheel" "@staff" "whitestrake"];
  };

  commonPackages = pkgs:
    with pkgs; [
      fish
      helix
      nh

      # File system tools
      dua
      tree
      rclone

      # Search tools
      fd
      ripgrep

      # Data inspection
      jq
      fx

      # Network clients
      wget
      curl
      xh

      # Troubleshooting
      btop
      mtr
      tcpdump
      dig
      whois
      rdap
      iperf
    ];
in {
  den.aspects.common-base = {
    nixos = {
      pkgs,
      unstable,
      ...
    }: {
      nix.settings =
        sharedNixSettings
        // {
          download-buffer-size = 524288000;
          substituters = [caches.garnix.url caches.nix-community.url];
          trusted-public-keys = [caches.garnix.key caches.nix-community.key];
        };

      nixpkgs.overlays = [
        (final: prev: {
          inherit unstable;
          myPkgs = mkLocalPackages {
            pkgs = final;
            unstablePkgs = unstable;
          };
        })
      ];

      environment.systemPackages = commonPackages pkgs;
    };

    darwin = {pkgs, ...}: {
      nix.settings = sharedNixSettings;
      environment.systemPackages = commonPackages pkgs;

      environment.etc."nix/nix.custom.conf".text = let
        substituters = map (c: c.url) (builtins.attrValues caches);
        keys = map (c: c.key) (builtins.attrValues caches);
      in ''
        trusted-users = root @admin @staff whitestrake
        extra-substituters = ${builtins.concatStringsSep " " substituters}
        extra-trusted-public-keys = ${builtins.concatStringsSep " " keys}
      '';
    };
  };

  den.aspects.linux-base = {
    includes = [
      den.aspects.common-base
      den.aspects.distributed-builds
    ];

    nixos = {
      pkgs,
      lib,
      ...
    }: {
      nix.settings.auto-optimise-store = true;
      programs.nh = {
        enable = true;
        flake = "github:whitestrake/nixos";
        clean = {
          enable = true;
          dates = "daily";
          extraArgs = "--keep-since 7d --keep 5";
        };
      };

      nixpkgs.overlays = [
        (final: prev: {
          dhcpcd = final.unstable.dhcpcd;
        })
      ];

      # Allow non-nix executables
      programs.nix-ld.enable = true;

      # Allow sudo via SSH key
      security.pam.sshAgentAuth.enable = true;
      security.pam.services.sudo.sshAgentAuth = true;

      environment.systemPackages = with pkgs; [
        service-wrapper
        iftop
        iotop
        ethtool
        lsof
        pciutils
        usbutils
      ];

      # Set up basic SSH protection
      services.sshguard.enable = true;
      systemd.services.sshguard.serviceConfig.TimeoutStopSec = "10s";
      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = "no";
          PasswordAuthentication = false;
        };
      };

      # Tailscale networking
      services.tailscale = {
        enable = lib.mkDefault true;
        package = pkgs.unstable.tailscale;
        useRoutingFeatures = lib.mkDefault "client";
        openFirewall = true;
      };

      # www-data user
      users.users.www-data = {
        isSystemUser = true;
        group = "www-data";
        uid = 33;
      };
      users.groups.www-data.gid = 33;
    };
  };
}
