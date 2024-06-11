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
}
