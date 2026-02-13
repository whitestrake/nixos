{
  lib,
  pkgs,
  config,
  ...
}: {
  sops.secrets."hawser/server_url" = {};
  sops.secrets."hawser/token_${config.networking.hostName}" = {};
  sops.templates."hawserEnv" = {
    content = ''
      DOCKHAND_SERVER_URL=${config.sops.placeholder."hawser/server_url"}
      TOKEN=${config.sops.placeholder."hawser/token_${config.networking.hostName}"}
    '';
  };

  systemd.services.hawser = {
    description = "Hawser - Remote Docker Agent for Dockhand";
    documentation = ["https://github.com/Finsys/hawser"];
    after = ["network-online.target" "docker.service"];
    wants = ["network-online.target"];
    requires = ["docker.service"];
    wantedBy = ["multi-user.target"];

    environment = {
      DOCKER_SOCKET = lib.mkDefault "/var/run/docker.sock";
      STACKS_DIR = lib.mkDefault "/opt/docker";
      AGENT_NAME = lib.mkDefault (lib.strings.toSentenceCase config.networking.hostName);
    };

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.myPkgs.hawser}/bin/hawser";
      Restart = "always";
      RestartSec = 10;
      EnvironmentFile = config.sops.templates.hawserEnv.path;

      # Security hardening
      NoNewPrivileges = false;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = ["/var/run/docker.sock" "/opt/docker"];
    };
  };
}
