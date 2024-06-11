{inputs, ...}: {
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    auto-optimise-store = true;
    trusted-users = ["@wheel" "@staff"];
  };

  nix.gc = {
    automatic = true;
    options = "--delete-older-than 30d";
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

  # Enable fish by default
  programs.fish.enable = true;
}
