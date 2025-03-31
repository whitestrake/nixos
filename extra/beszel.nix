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
      DynamicUser = true;
      Restart = "always";
      EnvironmentFile = config.sops.secrets.beszelEnv.path;
      ExecStart = "${pkgs.unstable.beszel}/bin/beszel-agent";
      StateDirectory = "beszel-agent";

      # Security/sandboxing
      KeyringMode = "private";
      LockPersonality = "yes";
      ProtectClock = "yes";
      ProtectHostname = "yes";
      ProtectKernelLogs = "yes";
      ProtectKernelTunables = "yes";
      SystemCallArchitectures = "native";
      SupplementaryGroups =
        lib.optional config.virtualisation.docker.enable "docker"
        ++ lib.optional config.virtualisation.podman.enable "podman";
    };
  };
}
