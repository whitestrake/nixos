{
  pkgs,
  inputs,
  ...
}: {
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    auto-optimise-store = true;
    trusted-users = ["@wheel" "@staff"];
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };

  nix.gc = {
    automatic = true;
    options = "--delete-older-than 30d";
  };

  nixpkgs.overlays = [
    # Add unstable package set to pkgs
    (final: _prev: {
      unstable = import inputs.nixpkgs-unstable {
        system = final.system;
        config.allowUnfree = true;
      };
    })

    # https://github.com/oxalica/nil/issues/113
    inputs.nil.overlays.default
  ];

  # Enable fish by default
  programs.fish.enable = true;

  # Allow unfree and configure base system packages
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    # Misc
    btop
    rar
    fish
    powershell
    helix

    # Files
    unstable.ncdu
    tree
    ranger
    rclone

    # HTTP
    wget
    curl

    # JSON
    jq
    fx

    # Net
    dig
    whois
    rdap
    iperf
  ];
}
