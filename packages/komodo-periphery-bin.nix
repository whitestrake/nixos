{
  lib,
  pkgs,
  ...
}: let
  version = "2.3.2";
  assets = {
    "aarch64-darwin" = {
      name = "periphery-apple";
      hash = "sha256-hx/XnbSw3iexuM65t02hFMwD3vYyNQST22XU33JLq3I=";
    };
    "x86_64-linux" = {
      name = "periphery-x86_64";
      hash = "sha256-KbQiOZY6pVJp/RnR3OF2PbQlwzkYwpSN09+qVVvjrQo=";
    };
    "aarch64-linux" = {
      name = "periphery-aarch64";
      hash = "sha256-Z8EHwmcKw6qSAt9XuStwbu5P75Yg6Pr+cz2d86ZrWls=";
    };
  };
  system = pkgs.stdenv.hostPlatform.system;
  asset = assets.${system} or (throw "komodo-periphery-bin: unsupported system ${system}");
in
  pkgs.stdenvNoCC.mkDerivation {
    pname = "komodo-periphery-bin";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/moghtech/komodo/releases/download/v${version}/${asset.name}";
      inherit (asset) hash;
    };

    dontUnpack = true;
    nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [pkgs.autoPatchelfHook];
    buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [pkgs.stdenv.cc.cc.lib pkgs.glibc pkgs.openssl];

    installPhase = ''
      runHook preInstall
      install -Dm755 $src $out/bin/periphery
      runHook postInstall
    '';

    passthru.updateScript = lib.getExe (pkgs.writeShellApplication {
      name = "update-komodo-periphery-bin";
      runtimeInputs = [pkgs.gitMinimal pkgs.nix];
      text = ''
        exec ${pkgs.python3}/bin/python3 ${./update-github-binary-release.py} moghtech/komodo v "$@"
      '';
    });

    meta = {
      description = "Agent for connecting servers to Komodo Core";
      homepage = "https://komo.do";
      changelog = "https://github.com/moghtech/komodo/releases/tag/v${version}";
      license = lib.licenses.gpl3;
      mainProgram = "periphery";
      platforms = builtins.attrNames assets;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
