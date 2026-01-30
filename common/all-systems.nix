{
  pkgs,
  inputs,
  config,
  lib,
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

  nixpkgs.overlays = [
    (final: prev: {
      # Overlay nixpkgs-unstable
      unstable = import inputs.nixpkgs-unstable {
        system = final.pkgs.stdenv.hostPlatform.system;
        config.allowUnfree = true;
      };

      # Overlay local pkgs
      myPkgs = import ../pkgs {pkgs = final;};
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

  # If we have deploy-rs installed, add the async alias from the PR too
  environment.shellAliases.deploy-rs-async = lib.mkIf (lib.elem pkgs.deploy-rs config.environment.systemPackages) (let
    system = pkgs.stdenv.hostPlatform.system;
    deploy-rs-async = inputs.deploy-rs-async.packages.${system}.deploy-rs;
  in "${deploy-rs-async}/bin/deploy --remote-build");
}
