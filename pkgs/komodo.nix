{pkgs, ...}: let
  version = "2.1.1";
  src = pkgs.fetchFromGitHub {
    owner = "moghtech";
    repo = "komodo";
    tag = "v${version}";
    hash = "sha256-kcWFpfvgKOQSQsjKEfiHDj9WjhoBOY6q3eHUpdRhApM=";
  };
in
  pkgs.komodo.overrideAttrs (oldAttrs: {
    inherit version src;
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "komodo-${version}";
      hash = "sha256-RmNAlvKrjqGyzaJRi2hQmVzR+j5HioIYytgS1GBjXGs=";
    };
    nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [pkgs.pkg-config];
    buildInputs = (oldAttrs.buildInputs or []) ++ [pkgs.openssl];
  })
