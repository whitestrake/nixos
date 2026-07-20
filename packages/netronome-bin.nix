{
  lib,
  pkgs,
  ...
}: let
  version = "0.11.0";
  assets = {
    "aarch64-darwin" = {
      name = "netronome_${version}_darwin_arm64.tar.gz";
      hash = "sha256-Y2VlIazvNXkeK/oPVvm3q+E9yRucecodoA83yVZ7Erg=";
    };
    "x86_64-linux" = {
      name = "netronome_${version}_linux_x86_64.tar.gz";
      hash = "sha256-P943F7Sal6MlMxtaLP0OXcq6owiS1m/esq5nKZm1rPg=";
    };
    "aarch64-linux" = {
      name = "netronome_${version}_linux_arm64.tar.gz";
      hash = "sha256-Z5wDQTE+YtGtrRMhfnnzNeZ/wmgU0vaIFarCDSSHmO4=";
    };
  };
  system = pkgs.stdenv.hostPlatform.system;
  asset = assets.${system} or (throw "netronome-bin: unsupported system ${system}");
in
  pkgs.stdenvNoCC.mkDerivation {
    pname = "netronome-bin";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/autobrr/netronome/releases/download/v${version}/${asset.name}";
      inherit (asset) hash;
    };

    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      tar -xzf $src -O netronome >$out/bin/netronome
      chmod +x $out/bin/netronome
      runHook postInstall
    '';

    passthru.updateScript = lib.getExe (pkgs.writeShellApplication {
      name = "update-netronome-bin";
      runtimeInputs = [pkgs.gitMinimal pkgs.nix];
      text = ''
        exec ${pkgs.python3}/bin/python3 ${./update-github-binary-release.py} autobrr/netronome v "$@"
      '';
    });

    meta = {
      description = "Modern network speed testing and monitoring tool";
      homepage = "https://github.com/autobrr/netronome";
      changelog = "https://github.com/autobrr/netronome/releases/tag/v${version}";
      license = lib.licenses.gpl2Only;
      mainProgram = "netronome";
      platforms = builtins.attrNames assets;
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
