{
  pkgs,
  inputs,
  ...
}: {
  imports = [inputs.home-manager.darwinModules.home-manager];

  # Enable touch ID for sudo
  security.pam.enableSudoTouchIdAuth = true;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;

  fonts.fontDir.enable = true;
  fonts.fonts = with pkgs; [
    (nerdfonts.override {
      fonts = [
        "FiraCode"
        "DroidSansMono"
        "Meslo"
        "Inconsolata"
      ];
    })
  ];

  # Unstable nixpkgs access
  nixpkgs.overlays = [
    (final: _prev: {
      unstable = import inputs.nixpkgs-unstable {
        system = final.system;
        config.allowUnfree = true;
      };
    })
  ];

  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    btop
    tree
    ranger
    rclone
    rar
    powershell
    iperf
    watch
    go
    caddy
    xcaddy
    duplicacy
    wget
    curl
    dig
    jq
    fx
    age
    sops
    deploy-rs
    nil
    alejandra

    # https://github.com/NixOS/nixpkgs/issues/287861
    unstable.ncdu
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
      "visual-studio-code"
      "notunes"
      "iina"
      "raycast"
      "warp"
      "obsidian"
    ];
  };

  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;
  nix.package = pkgs.nix;
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    auto-optimise-store = true;
  };

  # User configuration
  programs.fish.enable = true;
  programs.zsh.enable = true;
  users.users.whitestrake.shell = pkgs.fish;
  users.users.whitestrake.home = "/Users/whitestrake";
  home-manager.users.whitestrake = {lib, ...}: {
    imports = [../users/whitestrake/home.nix];
    home.sessionVariables.EDITOR = lib.mkForce "code"; # VS Code
    home.sessionVariables.CLICOLOR = lib.mkForce "1"; # Enable colours in terminal outputs
    home.shellAliases.tailscale = lib.mkForce "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
    programs.fish.interactiveShellInit = lib.mkForce ''
      set fish_greeting
      thefuck --alias | source
      fish_add_path $GOPATH/bin/
    '';
  };
}
