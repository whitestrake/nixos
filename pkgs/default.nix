{pkgs}: {
  komodo = import ./komodo.nix {inherit pkgs;};
  beszel = import ./beszel.nix {inherit pkgs;};
}
