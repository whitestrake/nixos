{
  pkgs ? import <nixpkgs> {},
  unstablePkgs ? pkgs,
}: {
  caddy = pkgs.callPackage ./caddy.nix {};
  komodo = pkgs.callPackage ./komodo.nix {};
  beszel = pkgs.callPackage ./beszel.nix {inherit unstablePkgs;};
  hawser = pkgs.callPackage ./hawser.nix {};
  netronome = pkgs.callPackage ./netronome.nix {};
  lz4 = pkgs.callPackage ./lz4.nix {};
}
