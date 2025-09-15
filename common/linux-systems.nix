{
  config,
  pkgs,
  ...
}: {
  # Default system monitoring
  imports = [
    ../extra/beszel.nix
    ../extra/check_mk.nix
    ../extra/alloy.nix
    ../users/whitestrake
  ];

  # Allow non-nix executables
  programs.nix-ld.enable = true;
  # programs.nix-ld.libraries = with pkgs; [
  #   # Add any missing dynamic libraries for unpackaged programs
  #   # here, NOT in environment.systemPackages
  # ];

  # Allow sudo via SSH key
  security.pam.sshAgentAuth.enable = true;
  security.pam.services.sudo.sshAgentAuth = true;

  # Allow unfree and configure base system packages
  nixpkgs.config.allowUnfree = true;
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
    enable = true;
    package = pkgs.unstable.tailscale;
  };
  # Make tailscaled wait until it has an IP before telling systemd it's ready
  # Allows services like rsyncd to wait until after tailscaled.service
  # https://github.com/tailscale/tailscale/issues/11504
  systemd.services.tailscaled.serviceConfig.ExecStartPost = ''
    ${pkgs.coreutils}/bin/timeout 60s ${pkgs.bash}/bin/bash -c 'until ${config.services.tailscale.package}/bin/tailscale status --peers=false; do sleep 1; done'
  '';
}
