{pkgs, ...}: {
  # # Fix to allow non-nix executables
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
    whois
    rdap
  ];

  # Set up basic SSH protection
  services.sshguard.enable = true;
  services.openssh.enable = true;
  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
  };
}
