{
  pkgs,
  config,
  ...
}: {
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
      ExecStart = "${pkgs.unstable.komodo}/bin/periphery";
      Restart = "always";
    };
  };
}
