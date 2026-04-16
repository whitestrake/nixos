{pkgs, ...}: let
  version = "2.1.2";
  src = pkgs.fetchFromGitHub {
    owner = "moghtech";
    repo = "komodo";
    tag = "v${version}";
    hash = "sha256-Gq88ludr/l4/UqZ1Qbbdz6U/xvnilU4F4qdLY+u68Ro=";
  };
in
  pkgs.komodo.overrideAttrs (oldAttrs: {
    inherit version src;
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "komodo-${version}";
      hash = "sha256-H60WYnU9mmNioVZL298UEG7CLPZA4PMMZg3Bj7THaeM=";
    };
    nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [pkgs.pkg-config];
    buildInputs = (oldAttrs.buildInputs or []) ++ [pkgs.openssl];
  })
