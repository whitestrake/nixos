{
  pkgs,
  inputs,
  ...
}: {
  nix.settings = {
    download-buffer-size = 524288000; # 500 MiB
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["@wheel" "@staff"];
    substituters = [
      "https://cache.garnix.io"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  # Enable automatic nix optimisation
  nix.settings.auto-optimise-store = true;

  nixpkgs.overlays = [
    # Add unstable package set to pkgs
    (final: _prev: {
      unstable = import inputs.nixpkgs-unstable {
        system = final.pkgs.stdenv.hostPlatform.system;
        config.allowUnfree = true;
      };
    })
  ];

  # Enable fish by default
  programs.fish.enable = true;

  # Allow unfree and configure base system packages
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    # Misc
    btop
    fish
    powershell
    helix
    nh

    # Files
    dua
    tree
    rclone

    # HTTP
    wget
    curl
    xh

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
