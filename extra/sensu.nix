{
  pkgs,
  config,
  ...
}: {
  imports = [../secrets];
  sops.secrets.sensuEnv = {};

  systemd.services.sensu-agent = {
    after = ["network.target"];
    wantedBy = ["multi-user.target"];
    description = "Sensu-Go monitoring agent.";
    path = with pkgs; [bash];
    serviceConfig = {
      CacheDirectory = "sensu";
      DynamicUser = "true";
      EnvironmentFile = config.sops.secrets.sensuEnv.path;
      ExecStart = "${pkgs.sensu-go-agent}/bin/sensu-agent start";
      Restart = "always";
    };
  };
}
