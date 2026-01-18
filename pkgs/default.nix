{pkgs ? import <nixpkgs> {}}: {
  caddy = pkgs.callPackage ./caddy.nix {};
  komodo = pkgs.callPackage ./komodo.nix {};
  beszel = pkgs.callPackage ./beszel.nix {};
}
