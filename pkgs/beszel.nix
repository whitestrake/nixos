{
  pkgs,
  lib,
  stdenv,
}:
pkgs.beszel.overrideAttrs (oldAttrs: let
  version = "0.18.2";
in {
  inherit version;
  src = pkgs.fetchFromGitHub {
    owner = "henrygd";
    repo = "beszel";
    tag = "v${version}";
    hash = "sha256-7jXhlstGuQc3EP4fm5k9FD22nge0ecXVZAk8mXdyKc0=";
  };
  vendorHash = "sha256-OnCX/0DGtkcACuWxGfIreS6SSx9dKq+feWKSymtkABs=";

  # Add checkFlags specifically for Darwin to bypass sandbox network restrictions
  checkFlags =
    oldAttrs.checkFlags or []
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      "-skip=TestStartServer"
    ];
})
