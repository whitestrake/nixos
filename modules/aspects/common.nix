{
  den,
  inputs,
  config,
  lib,
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
          substituters = ["https://cache.garnix.io" "https://nix-community.cachix.org"];
          trusted-public-keys = [
            "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
            "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          ];
        };

      nixpkgs.overlays = [
        (final: prev: {
          inherit unstable;
          myPkgs = import ../../pkgs {
            pkgs = final;
            unstablePkgs = unstable;
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
    includes = [den.aspects.common-base];

    nixos = {
      pkgs,
      config,
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

      # Distributed builds configuration
      sops.secrets.nixBuilderKey = {};
      nix.distributedBuilds = true;
      nix.settings.builders-use-substitutes = true;
      nix.buildMachines = let
        mkMachine = attrs:
          {
            protocol = "ssh-ng";
            sshUser = "builder";
            sshKey = config.sops.secrets.nixBuilderKey.path;
            maxJobs = 4;
            supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
          }
          // attrs;
        systems = map mkMachine [
          {
            hostName = "jaeger.fell-monitor.ts.net";
            system = "aarch64-linux";
            publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUdmMlhib1Q0L0N3L2JWeDdVSkZEZVdsVjNnRVJQZXhKc2hBQ0hSZTlqY3Ygcm9vdEBqYWVnZXI=";
          }
          {
            hostName = "orthus.fell-monitor.ts.net";
            system = "x86_64-linux";
            publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUI0YjJjYXpXdWt0OHZyNEV0a1J4b29SQkhrYSswVXVNSTlSejlpeWt3dFcgcm9vdEBvcnRodXM=";
          }
        ];
      in
        # Don't include the current host in its own buildMachines list
        lib.filter (x: x.hostName != "${config.networking.hostName}.fell-monitor.ts.net") systems;

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
