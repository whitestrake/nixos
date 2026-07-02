{
  lib,
  pkgs,
  nix-update-script,
  ...
}: let
  version = "2.2.0";
  src = pkgs.fetchFromGitHub {
    owner = "moghtech";
    repo = "komodo";
    tag = "v${version}";
    hash = "sha256-Hw0JD4e/ODK19M/bZtX9foCu5c79XA8Jgv2fleltdLs=";
  };
in
  pkgs.komodo.overrideAttrs (oldAttrs: {
    inherit version src;
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      name = "komodo-${version}";
      hash = "sha256-b/AgQBmS1QfP+BOCT4xL8majVKobig5M2YJhGuXMToc=";
    };
    passthru =
      (oldAttrs.passthru or {})
      // {
        updateScript = nix-update-script {
          extraArgs = ["--flake"];
        };
      };
    # Local version is newer than nixpkgs; inherited upstream patches no longer apply.
    patches = [];
    requiredSystemFeatures = (oldAttrs.requiredSystemFeatures or []) ++ ["big-parallel"];
    nativeBuildInputs = lib.unique ((oldAttrs.nativeBuildInputs or []) ++ [pkgs.pkg-config]);
    buildInputs = lib.unique ((oldAttrs.buildInputs or []) ++ [pkgs.openssl]);
  })
