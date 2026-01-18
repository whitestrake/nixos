{
  config,
  lib,
  pkgs,
  meta,
  ...
}: {
  imports =
    [
      # I've been here the whole time
      ../users/whitestrake
    ]
    ++ lib.optional (meta.isServer or true) ./linux-servers.nix;

  # Enable automatic nix optimisation and nh-based gc
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
    systems = [
      (mkMachine {
        hostName = "jaeger.fell-monitor.ts.net";
        system = "aarch64-linux";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUdmMlhib1Q0L0N3L2JWeDdVSkZEZVdsVjNnRVJQZXhKc2hBQ0hSZTlqY3Ygcm9vdEBqYWVnZXI=";
      })
      (mkMachine {
        hostName = "pascal.fell-monitor.ts.net";
        system = "x86_64-linux";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUtnQVdRNElXb1NXQml2aUx4RlMrU0lvenVMMXgyRGQwZHZ6TUJKUS9YQkcgcm9vdEBwYXNjYWw=";
        speedFactor = 2;
        maxJobs = 8;
      })
      (mkMachine {
        hostName = "orthus.fell-monitor.ts.net";
        system = "x86_64-linux";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUI0YjJjYXpXdWt0OHZyNEV0a1J4b29SQkhrYSswVXVNSTlSejlpeWt3dFcgcm9vdEBvcnRodXM=";
      })
    ];
  in
    # Don't include the current host in its own buildMachines list
    lib.filter (x: x.hostName != "${config.networking.hostName}.fell-monitor.ts.net") systems;

  # Allow non-nix executables
  programs.nix-ld.enable = true;
  # programs.nix-ld.libraries = with pkgs; [
  #   # Add any missing dynamic libraries for unpackaged programs
  #   # here, NOT in environment.systemPackages
  # ];

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
  services.openssh.enable = true;
  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
  };

  # Tailscale networking
  services.tailscale = {
    enable = lib.mkDefault true;
    package = pkgs.unstable.tailscale;
    useRoutingFeatures = lib.mkDefault "client";
    openFirewall = true;
  };

  # www-data user
  users.users.www-data.isSystemUser = true;
  users.users.www-data.group = "www-data";
  users.users.www-data.uid = 33;
  users.groups.www-data.gid = 33;
}
