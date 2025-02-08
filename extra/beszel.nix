{
  pkgs,
  config,
  lib,
  ...
}: let
  cfg = {
    user = "beszel";
    group = "beszel";
    package = pkgs.unstable.beszel;
  };
in {
  imports = [../secrets];
  sops.secrets.beszelEnv = {};

  users.groups.${cfg.group} = {};
  users.users.${cfg.user} = {
    isSystemUser = true;
    group = cfg.group;
    extraGroups =
      lib.optional config.virtualisation.docker.enable "docker"
      ++ lib.optional config.virtualisation.podman.enable "podman";
  };

  systemd.services.beszel-agent = {
    description = "Beszel monitoring agent";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    path = [cfg.package];
    serviceConfig = {
      User = cfg.user;
      Group = cfg.group;
      Restart = "always";
      EnvironmentFile = config.sops.secrets.beszelEnv.path;
      ExecStart = "${cfg.package}/bin/beszel-agent";
      StateDirectory = "beszel-agent";

      # Security/sandboxing
      KeyringMode = "private";
      LockPersonality = "yes";
      NoNewPrivileges = "yes";
      PrivateTmp = "yes";
      ProtectClock = "yes";
      ProtectHome = "read-only";
      ProtectHostname = "yes";
      ProtectKernelLogs = "yes";
      ProtectKernelTunables = "yes";
      ProtectSystem = "strict";
      RemoveIPC = "yes";
      RestrictSUIDSGID = "true";
      SystemCallArchitectures = "native";
    };
  };
}
