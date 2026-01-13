{pkgs}:
pkgs.beszel.overrideAttrs (oldAttrs: rec {
  version = "0.18.2";
  src = pkgs.fetchFromGitHub {
    owner = "henrygd";
    repo = "beszel";
    tag = "v${version}";
    hash = "sha256-7jXhlstGuQc3EP4fm5k9FD22nge0ecXVZAk8mXdyKc0=";
  };
  vendorHash = "sha256-OnCX/0DGtkcACuWxGfIreS6SSx9dKq+feWKSymtkABs=";
})
