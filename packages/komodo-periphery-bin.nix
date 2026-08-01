{
  lib,
  pkgs,
  ...
}: let
  version = "2.3.1";
  assets = {
    "aarch64-darwin" = {
      name = "periphery-apple";
      hash = "sha256-/jw9OQLnocDPWiYX35IaCHVJEUPoeS6zh/NyEu3AJX0=";
    };
    "x86_64-linux" = {
      name = "periphery-x86_64";
      hash = "sha256-22cWUvOhGIwNFkNaZVL7MOs78xCSw23Wt9Y1L0vKtnY=";
    };
    "aarch64-linux" = {
      name = "periphery-aarch64";
      hash = "sha256-H7hdY9gDn8jnrAiBg2198+Fc/5E0a3mXmNEsmY7hb0s=";
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
