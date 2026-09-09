{
  lib,
  pkgs,
  ...
}: let
  version = "0.14.0";
  assets = {
    "aarch64-darwin" = {
      name = "netronome_${version}_darwin_arm64.tar.gz";
      hash = "sha256-AANu0MMBSUaq87RObfLDRf8Ph3g3fm4jNPwTneDE3Dw=";
    };
    "x86_64-linux" = {
      name = "netronome_${version}_linux_x86_64.tar.gz";
      hash = "sha256-NPca+H6RBcShqIGhXGXGU3fbBESK/e4RTYJ25JkPnM4=";
    };
    "aarch64-linux" = {
      name = "netronome_${version}_linux_arm64.tar.gz";
      hash = "sha256-MaJ7YRSvTflbJlcZe9TNbsRFmn0j0AZwfLdIxsflGOE=";
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
