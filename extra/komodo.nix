{
  pkgs,
  config,
  ...
}: let
  version = "1.19.4";
  arch =
    if pkgs.stdenv.hostPlatform.system == "aarch64-linux"
    then "aarch64"
    else "x86_64";
  hash =
    # nix hash convert --hash-algo sha256 (nix-prefetch-url $url)
    if arch == "aarch64"
    then "sha256-dbkJdoM63bdfXJVjUnSlIk6YVwGRRxQB0HhWPVj4l98="
    else "sha256-zBQGHWDhBiVRbMEHQZutkkd7CnARP0GO/N8eaP8qMN8=";

  komodo-next = pkgs.stdenv.mkDerivation {
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
      ExecStart = "${komodo-next}/bin/periphery";
      Restart = "always";
      RestartSec = "5s";
    };
  };
}
