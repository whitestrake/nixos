{pkgs}:
pkgs.beszel.overrideAttrs (oldAttrs: rec {
  version = "0.18.1";
  src = pkgs.fetchFromGitHub {
    owner = "henrygd";
    repo = "beszel";
    tag = "v${version}";
    hash = "sha256-TYTWfXO6Pf5Ok4mSMACbW7xxcsmXWOqo358ykUlCOuo=";
  };
  vendorHash = "sha256-OnCX/0DGtkcACuWxGfIreS6SSx9dKq+feWKSymtkABs=";
})
