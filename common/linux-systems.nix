{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    # Default system monitoring
    ../extra/beszel.nix
    ../extra/alloy.nix
    # ../extra/check_mk.nix

    # I've been here the whole time
    ../users/whitestrake
  ];

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
  nix.buildMachines = let
    protocol = "ssh-ng";
    sshUser = "builder";
    maxJobs = 4;
    sshKey = config.sops.secrets.nixBuilderKey.path;
    supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
    systems = [
      {
        inherit protocol sshUser sshKey supportedFeatures maxJobs;
        hostName = "jaeger.fell-monitor.ts.net";
        system = "aarch64-linux";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUdmMlhib1Q0L0N3L2JWeDdVSkZEZVdsVjNnRVJQZXhKc2hBQ0hSZTlqY3Ygcm9vdEBqYWVnZXI=";
      }
      {
        inherit protocol sshUser sshKey supportedFeatures;
        hostName = "pascal.fell-monitor.ts.net";
        system = "x86_64-linux";
        maxJobs = 8;
        speedFactor = 2;
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUtnQVdRNElXb1NXQml2aUx4RlMrU0lvenVMMXgyRGQwZHZ6TUJKUS9YQkcgcm9vdEBwYXNjYWw=";
      }
      {
        inherit protocol sshUser sshKey supportedFeatures maxJobs;
        hostName = "orthus.fell-monitor.ts.net";
        system = "x86_64-linux";
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUI0YjJjYXpXdWt0OHZyNEV0a1J4b29SQkhoYSswVXVNSTlSejlpeWt3dFcgcm9vdEBvcnRodXM=";
      }
    ];
  in
    # Don't include the current host in its own buildMachines list
    lib.filter (x: x.hostName != "${config.networking.hostName}.fell-monitor.ts.net") systems;
  nix.settings.builders-use-substitutes = true;
  nix.settings.connect-timeout = 5;

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
  };
  # Make tailscaled wait until it has an IP before telling systemd it's ready
  # Allows services like rsyncd to wait until after tailscaled.service
  # https://github.com/tailscale/tailscale/issues/11504
  systemd.services.tailscaled.serviceConfig.ExecStartPost = ''
    ${pkgs.coreutils}/bin/timeout 60s ${pkgs.bash}/bin/bash -c 'until ${config.services.tailscale.package}/bin/tailscale status --peers=false; do sleep 1; done'
  '';

  # www-data user
  users.users.www-data.isSystemUser = true;
  users.users.www-data.group = "www-data";
  users.users.www-data.uid = 33;
  users.groups.www-data.gid = 33;
}
