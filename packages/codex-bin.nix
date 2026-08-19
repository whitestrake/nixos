{
  lib,
  pkgs,
  ...
}: let
  version = "0.148.0";
  assets = {
    "aarch64-darwin" = {
      name = "codex-aarch64-apple-darwin";
      hash = "sha256-dYkWqjjvp60HagUIMPy+8aftb0Hvrpwczq7vY+Qo/Cs=";
    };
    "x86_64-linux" = {
      name = "codex-x86_64-unknown-linux-musl";
      hash = "sha256-Gjb3YvazvvUzu4Y0WtlRdmHC2E1TmWolDPLKidLP7lo=";
    };
    "aarch64-linux" = {
      name = "codex-aarch64-unknown-linux-musl";
      hash = "sha256-QQxq4Mdj6znG2hdmXmP5qkqY5u5mPYH46Ld5yXyxdaw=";
    };
  };
  system = pkgs.stdenv.hostPlatform.system;
  asset = assets.${system} or (throw "codex-bin: unsupported system ${system}");
in
  pkgs.stdenvNoCC.mkDerivation {
    pname = "codex-bin";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/${asset.name}.tar.gz";
      inherit (asset) hash;
    };

    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      tar -xzf $src -O ${asset.name} >$out/bin/codex
      chmod +x $out/bin/codex
      runHook postInstall
    '';

    passthru.updateScript = lib.getExe (pkgs.writeShellApplication {
      name = "update-codex-bin";
      runtimeInputs = [pkgs.gitMinimal pkgs.nix];
      text = ''
        exec ${pkgs.python3}/bin/python3 ${./update-github-binary-release.py} openai/codex rust-v "$@"
      '';
    });

    meta = {
      description = "Lightweight coding agent that runs in your terminal";
      homepage = "https://github.com/openai/codex";
      changelog = "https://github.com/openai/codex/releases/tag/rust-v${version}";
      license = lib.licenses.asl20;
      mainProgram = "codex";
      platforms = builtins.attrNames assets;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
