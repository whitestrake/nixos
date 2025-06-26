{
  pkgs,
  config,
  ...
}: let
  version = "1.18.4";
  arch =
    if pkgs.stdenv.hostPlatform.system == "aarch64-linux"
    then "aarch64"
    else "x86_64";
  hash =
    # nix hash convert --hash-algo sha256 (nix-prefetch-url $url)
    if arch == "aarch64"
    then "sha256-JG25YNR0p24iR7PsFBNT4GGr/4d41KmDjE0Bdnwl9Yg="
    else "sha256-kF6iurDAI8fOHNIwTJ2Oypn4dIBEdoxYl8m1RGmJ5IY=";

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
    path = with pkgs; [bash docker];
    serviceConfig = {
      EnvironmentFile = config.sops.secrets.komodoEnv.path;
      ExecStart = "${komodo-next}/bin/periphery";
      Restart = "always";
      RestartSec = "5s";
    };
  };
}
