{pkgs, ...}: {
  imports = [
    ./all-systems.nix
  ];

  # Enable touch ID for sudo
  security.pam.services.sudo_local.touchIdAuth = true;

  # Disable downloaded file quarantine
  system.defaults.LaunchServices.LSQuarantine = false;

  # Fonts for system
  fonts.packages = with pkgs; [
    nerd-fonts.meslo-lg
    nerd-fonts.fira-code
    nerd-fonts.inconsolata
    nerd-fonts.droid-sans-mono
  ];

  # Allow unfree and configure base system packages
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    watch
    go
    caddy
    xcaddy
    duplicacy
    zulu
    samba
  ];

  # Add shells to /etc/shells so that they can be selected for by users
  environment.shells = with pkgs; [fish];

  # Use Homebrew for GUI apps; nix-darwin and home-manager suck at it
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = true;
      upgrade = true;
      cleanup = "zap";
    };
    brews = [
      "bitwarden-cli"
    ];
    casks = [
      "music-decoy"
      "visual-studio-code"
      "iina"
      "raycast"
      "warp"
      "obsidian"
      "soduto"
      "kando"
    ];
  };

  # Auto upgrade nix package and the daemon service.
  nix.enable = true;
  nix.package = pkgs.nix;
}
