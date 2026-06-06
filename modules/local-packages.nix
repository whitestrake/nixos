{
  inputs,
  flakeRoot,
  ...
}: let
  # Single access path for the local package set. Both the perSystem packages
  # output and the myPkgs overlay consume this, so the lib/local-packages.nix
  # pure function and its argument wiring live in exactly one place.
  mkLocalPackages = {
    pkgs,
    unstablePkgs,
  }:
    import (flakeRoot + "/pkgs") {
      inherit (pkgs) lib;
      inherit pkgs unstablePkgs;
      inherit (inputs) import-tree;
    };
in {
  _module.args.mkLocalPackages = mkLocalPackages;
}
