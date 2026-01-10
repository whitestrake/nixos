{
  pkgs,
  config,
  inputs,
  ...
}: let
  komodo = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.komodo;
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
      ExecStart = "${komodo}/bin/periphery";
      Restart = "always";
      RestartSec = "5s";
    };
  };
}
