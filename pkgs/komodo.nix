{pkgs, ...}: let
  version = "2.0.0";
  src = pkgs.fetchFromGitHub {
    owner = "moghtech";
    repo = "komodo";
    tag = "v${version}";
    hash = "sha256-OcUvslIMtxDVJTO0wSZsxCvNUbIACYPScgre4OoETX4=";
  };
in
  pkgs.komodo.overrideAttrs (oldAttrs: {
    inherit version src;
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "komodo-${version}";
      hash = "sha256-jcfTAAVTcZ4IcjrzVn3dyWgSzkqtSs4vUHM/u2PfXLU=";
    };
    nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [pkgs.pkg-config];
    buildInputs = (oldAttrs.buildInputs or []) ++ [pkgs.openssl];
  })
