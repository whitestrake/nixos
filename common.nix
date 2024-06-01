{
  pkgs,
  inputs,
  ...
}: {
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    auto-optimise-store = true;
    trusted-users = ["@wheel"];
  };

  # Add unstable package set to pkgs
  nixpkgs.overlays = [
    (final: _prev: {
      unstable = import inputs.nixpkgs-unstable {
        system = final.system;
        config.allowUnfree = true;
      };
    })
  ];

  # Fix to allow non-nix executables
  # programs.nix-ld.enable = true;
  # programs.nix-ld.libraries = with pkgs; [
  #   # Add any missing dynamic libraries for unpackaged programs
  #   # here, NOT in environment.systemPackages
  # ];

  # Allow sudo via SSH key
  security.pam.enableSSHAgentAuth = true;
  security.pam.services.sudo.sshAgentAuth = true;

  # Allow unfree and configure base system packages
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    btop
    iftop
    iotop
    tmux
    ncdu
    service-wrapper
    tree
    ranger
    rclone
    wget
    curl
    dig
    jq
    fx
    ethtool
    pciutils
    usbutils
    sops
    age
    deploy-rs
  ];

  # Enable the fish shell by default
  programs.fish.enable = true;

  # Enable git usage
  programs.git.enable = true;

  # Set up basic SSH protection
  services.fail2ban.enable = true;
  services.openssh.enable = true;
  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
    LogLevel = "VERBOSE";
  };
}
