{
  lib,
  pkgs,
  ...
}: let
  version = "0.158.0";
  assets = {
    "aarch64-darwin" = {
      name = "codex-aarch64-apple-darwin";
      hash = "sha256-NBxKCPnOGTWzAHN23Co9UKCokRKTDppHSuYTZyGPboo=";
    };
    "x86_64-linux" = {
      name = "codex-x86_64-unknown-linux-musl";
      hash = "sha256-r59apuZmKsz51wfO8NnKCDiAoXOpwrbCKUftt4MOV3g=";
    };
    "aarch64-linux" = {
      name = "codex-aarch64-unknown-linux-musl";
      hash = "sha256-keP6/l/4Raj2haBdBJGRRvsw/ckkWvGkKi9/I5lZ6Qw=";
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
