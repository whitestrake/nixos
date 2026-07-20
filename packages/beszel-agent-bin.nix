{
  lib,
  pkgs,
  ...
}: let
  version = "0.18.7";
  assets = {
    "aarch64-darwin" = {
      name = "beszel-agent_darwin_arm64.tar.gz";
      hash = "sha256-bx0pq84hTsjsXm9vX71yvVKET+oIy0eT+DxpUho7lE8=";
    };
    "x86_64-linux" = {
      name = "beszel-agent_linux_amd64.tar.gz";
      hash = "sha256-SuMnqsWtWiMYRbDvYTBm1VW75S9+yy8opT0HwE5omv8=";
    };
    "aarch64-linux" = {
      name = "beszel-agent_linux_arm64.tar.gz";
      hash = "sha256-ATQlYGiTfKt0t/JuNwB6S1vz1SzUBJaouLDru7Gm8C8=";
    };
  };
  system = pkgs.stdenv.hostPlatform.system;
  asset = assets.${system} or (throw "beszel-agent-bin: unsupported system ${system}");
in
  pkgs.stdenvNoCC.mkDerivation {
    pname = "beszel-agent-bin";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/henrygd/beszel/releases/download/v${version}/${asset.name}";
      inherit (asset) hash;
    };

    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      tar -xzf $src -O beszel-agent >$out/bin/beszel-agent
      chmod +x $out/bin/beszel-agent
      runHook postInstall
    '';

    passthru.updateScript = lib.getExe (pkgs.writeShellApplication {
      name = "update-beszel-agent-bin";
      runtimeInputs = [pkgs.gitMinimal pkgs.nix];
      text = ''
        exec ${pkgs.python3}/bin/python3 ${./update-github-binary-release.py} henrygd/beszel v "$@"
      '';
    });

    meta = {
      description = "Lightweight server monitoring agent";
      homepage = "https://github.com/henrygd/beszel";
      changelog = "https://github.com/henrygd/beszel/releases/tag/v${version}";
      license = lib.licenses.mit;
      mainProgram = "beszel-agent";
      platforms = builtins.attrNames assets;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
