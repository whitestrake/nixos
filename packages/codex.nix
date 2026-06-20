{
  pkgs,
  unstablePkgs ? pkgs,
  ...
}: let
  version = "0.141.0";

  systemMap = {
    "aarch64-darwin" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-aarch64-apple-darwin.tar.gz";
      hash = "sha256-q96tX+68JZ3squwzRlQju7eQSzBJ+ijpIgnLkkaTwPQ=";
    };
    "x86_64-linux" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-x86_64-unknown-linux-musl.tar.gz";
      hash = "sha256-8eK/n6C6brghGdYhtrcbw47dM8BtwoZ7MaAnBSNYlX0=";
    };
    "aarch64-linux" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-aarch64-unknown-linux-musl.tar.gz";
      hash = "sha256-jJ8xgR1ln8wXxfGiG8CXGYRGnJ46Y8Kzm2HMdpTzoQE=";
    };
  };

  system = pkgs.stdenv.hostPlatform.system;
in
  if systemMap ? ${system}
  then let
    asset = systemMap.${system};
  in
    pkgs.stdenv.mkDerivation {
      pname = "codex";
      inherit version;

      src = pkgs.fetchurl {
        inherit (asset) url hash;
      };

      sourceRoot = ".";

      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        if [ -f codex ]; then
          cp codex $out/bin/codex
        elif [ -f bin/codex ]; then
          cp bin/codex $out/bin/codex
        else
          binary=$(find . -maxdepth 1 -type f -name "codex-*" | head -n 1)
          if [ -n "$binary" ]; then
            cp "$binary" $out/bin/codex
          else
            echo "Error: Could not find codex binary in source"
            exit 1
          fi
        fi
        chmod +x $out/bin/codex
        runHook postInstall
      '';

      meta = {
        mainProgram = "codex";
      };
    }
  else
    unstablePkgs.codex.overrideAttrs (oldAttrs: let
      src = pkgs.fetchFromGitHub {
        owner = "openai";
        repo = "codex";
        tag = "rust-v${version}";
        hash = "sha256-1ZOaZlwAkH6DJpxlInfbXpaqmsbOIOGrFoj2dYehBMA=";
      };
    in {
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
    })
