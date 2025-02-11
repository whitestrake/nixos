{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [../secrets];
  sops.secrets.beszelEnv = {};

  systemd.services.beszel-agent = {
    description = "Beszel monitoring agent";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      DymamicUser = true;
      Restart = "always";
      EnvironmentFile = config.sops.secrets.beszelEnv.path;
      ExecStart = "${pkgs.unstable.beszel}/bin/beszel-agent";
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
      SupplementaryGroups =
        lib.optional config.virtualisation.docker.enable "docker"
        ++ lib.optional config.virtualisation.podman.enable "podman";
    };
  };
}
