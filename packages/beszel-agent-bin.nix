{
  lib,
  pkgs,
  ...
}: let
  version = "0.19.0";
  assets = {
    "aarch64-darwin" = {
      name = "beszel-agent_darwin_arm64.tar.gz";
      hash = "sha256-pai6RqiGEPXaTqqjLxhGQuBvIIhffm4eo2B1lq75yxs=";
    };
    "x86_64-linux" = {
      name = "beszel-agent_linux_amd64.tar.gz";
      hash = "sha256-D4WJGykBRrM29cgT0eU16ZLaNe553odukg4ux0ircyw=";
    };
    "aarch64-linux" = {
      name = "beszel-agent_linux_arm64.tar.gz";
      hash = "sha256-OgsMRxUGoC2N550D96RRMrVAEK3BBcYgj/6Liu3B2jg=";
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
