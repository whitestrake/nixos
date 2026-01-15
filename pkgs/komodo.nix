{pkgs}:
pkgs.komodo.overrideAttrs (oldAttrs: let
  version = "1.19.5";
  src = pkgs.fetchFromGitHub {
    owner = "moghtech";
    repo = "komodo";
    tag = "v${version}";
    hash = "sha256-dLBgdcrIp5QM2TVIa86qX7m1c5n+qOIQJtqJPGvIZ+0=";
  };
in {
  inherit version src;
  cargoDeps = oldAttrs.cargoDeps.overrideAttrs {
    inherit src;
    outputHash = "sha256-e2nw9DL4dpHOFEYiBoQOCVWKryQp6ZOcwI8w0wJ/HFM=";
    outputHashMode = "recursive";
  };
})
