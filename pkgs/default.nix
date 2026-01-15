{pkgs}: {
  komodo = pkgs.callPackage ./komodo.nix {};
  beszel = pkgs.callPackage ./beszel.nix {};
}
