{pkgs, ...}: {
  imports = [
    ./all-systems.nix
  ];

  # Enable touch ID for sudo
  security.pam.enableSudoTouchIdAuth = true;

  # Disable downloaded file quarantine
  system.defaults.LaunchServices.LSQuarantine = false;

  # Fonts for system
  fonts.packages = with pkgs; [
    (nerdfonts.override {
      fonts = [
        "FiraCode"
        "DroidSansMono"
        "Meslo"
        "Inconsolata"
      ];
    })
  ];

  # Allow unfree and configure base system packages
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    watch
    go
    caddy
    xcaddy
    duplicacy
  ];

  # Add shells to /etc/shells so that they can be selected for by users
  environment.shells = with pkgs; [fish];

  # Use Homebrew for GUI apps; nix-darwin and home-manager suck at it
  homebrew = {
    enable = true;
    onActivation.autoUpdate = true;
    onActivation.upgrade = true;
    brews = [
      "samba"
      "bitwarden-cli"
      "java"
      "curl"
    ];
    casks = [
      "music-decoy"
      "visual-studio-code"
      "iina"
      "raycast"
      "warp"
      "obsidian"
    ];
  };

  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;
  nix.package = pkgs.nix;
}
