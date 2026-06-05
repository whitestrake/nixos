{
  den,
  inputs,
  flakeRoot,
  caches,
  ...
}: let
  sharedNixSettings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@wheel" "@staff" "whitestrake"];
  };
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
          myPkgs = import (flakeRoot + "/lib/local-packages.nix") {
            inherit (final) lib;
            pkgs = final;
            unstablePkgs = unstable;
            inherit (inputs) import-tree;
            packageDir = flakeRoot + "/pkgs";
          };
        })
      ];

      environment.systemPackages = with pkgs; [
        btop
        fish
        helix
        nh
        dua
        tree
        rclone
        wget
        curl
        xh
        jq
        fx
        dig
        whois
        rdap
        iperf
      ];
    };

    darwin = {pkgs, ...}: {
      nix.settings = sharedNixSettings;
      environment.systemPackages = with pkgs; [
        btop
        fish
        helix
        nh
        dua
        tree
        rclone
        wget
        curl
        xh
        jq
        fx
        dig
        whois
        rdap
        iperf
        ripgrep
        fd
      ];
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
