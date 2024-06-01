{
  pkgs,
  config,
  ...
}: {
  imports = [../secrets];
  sops.secrets.sensuEnv = {};

  users.groups.sensu = {};
  users.users.sensu.isSystemUser = true;
  users.users.sensu.group = "sensu";

  systemd.services.sensu-agent = {
    wantedBy = ["multi-user.target"];
    after = ["network.target"];
    description = "Sensu-Go monitoring agent.";
    path = with pkgs; [bash];
    serviceConfig = {
      User = "sensu";
      Group = "sensu";
      Restart = "always";
      EnvironmentFile = config.sops.secrets.sensuEnv.path;
      ExecStart = "${pkgs.sensu-go-agent}/bin/sensu-agent start --backend-url $URL --password $PASS";
    };
  };

  systemd.tmpfiles.rules = ["d /var/cache/sensu 0750 sensu sensu"];
}
