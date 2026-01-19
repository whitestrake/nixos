{
  lib,
  pkgs,
  config,
  ...
}: {
  imports = [../secrets];
  sops.secrets.hawserEnv = {};

  systemd.services.hawser = {
    description = "Hawser - Remote Docker Agent for Dockhand";
    documentation = ["https://github.com/Finsys/hawser"];
    after = ["network-online.target" "docker.service"];
    wants = ["network-online.target"];
    requires = ["docker.service"];
    wantedBy = ["multi-user.target"];

    environment = {
      DOCKER_SOCKET = lib.mkDefault "/var/run/docker.sock";
      AGENT_NAME = lib.mkDefault (lib.strings.toSentenceCase config.networking.hostName);
    };

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.myPkgs.hawser}/bin/hawser";
      Restart = "always";
      RestartSec = 10;
      EnvironmentFile = config.sops.secrets.hawserEnv.path;

      # Security hardening
      NoNewPrivileges = false;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = ["/var/run/docker.sock" "/opt/docker/dockhand"];
    };
  };
}
