{pkgs ? import <nixpkgs> {}}: {
  caddy = pkgs.callPackage ./caddy.nix {};
  komodo = pkgs.callPackage ./komodo.nix {};
  beszel = pkgs.callPackage ./beszel.nix {};
  hawser = pkgs.callPackage ./hawser.nix {};
  netronome = pkgs.callPackage ./netronome.nix {};
}
