{
  pkgs,
  unstablePkgs ? pkgs,
  ...
}: let
  version = "0.141.0";

  src = pkgs.fetchFromGitHub {
    owner = "openai";
    repo = "codex";
    tag = "rust-v${version}";
    hash = "sha256-1ZOaZlwAkH6DJpxlInfbXpaqmsbOIOGrFoj2dYehBMA=";
  };
in
  unstablePkgs.codex.overrideAttrs {
    inherit version src;

    cargoDeps = unstablePkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      sourceRoot = "${src.name}/codex-rs";
      name = "codex-${version}";
      hash = "sha256-bQPeRKTrNYeGCO20hpu+F37sScFOGr1EPOVf1E0FU+4=";
    };

    postPatch = ''
      substituteInPlace $cargoDepsCopy/*/webrtc-sys-*/build.rs \
        --replace-fail "cargo:rustc-link-lib=static=webrtc" "cargo:rustc-link-lib=dylib=webrtc"
      substituteInPlace Cargo.toml \
        --replace-fail 'lto = "thin"' "" \
        --replace-fail 'codegen-units = 4' ""
    '';
  }
