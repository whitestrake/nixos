{
  pkgs,
  config,
  ...
}: let
  version = "1.19.5";
  arch = pkgs.stdenv.hostPlatform.uname.processor;
  hash =
    {
      # nix hash convert --hash-algo sha256 (nix-prefetch-url $url)
      aarch64 = "sha256-aCsoDaLwm1tsDch9HLURo1yTBnDgCICEU/hppokv4RE=";
      x86_64 = "sha256-1uics2Avffe2TEPTWJLGQVeBGcJFGWuu0oV9fQeFlHA=";
    }.${
      arch
    };

  komodo-periphery = pkgs.stdenv.mkDerivation {
    pname = "komodo-periphery";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/moghtech/komodo/releases/download/v${version}/periphery-${arch}";
      inherit hash;
    };

    phases = ["installPhase"];
    installPhase = ''
      install -Dm755 $src $out/bin/periphery
    '';
  };
in {
  imports = [../secrets];
  sops.secrets.komodoEnv = {};

  systemd.services.komodo-periphery = {
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    description = "Agent to connect with Komodo Core";
    path = with pkgs; [bash docker openssl];
    serviceConfig = {
      EnvironmentFile = config.sops.secrets.komodoEnv.path;
      ExecStart = "${komodo-periphery}/bin/periphery";
      Restart = "always";
      RestartSec = "5s";
    };
  };
}
