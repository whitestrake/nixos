{
  config,
  pkgs,
  lib,
  ...
}: let
  beszel-next = pkgs.unstable.beszel.overrideAttrs (oldAttrs: rec {
    version = "0.11.1";
    src = pkgs.fetchFromGitHub {
      owner = "henrygd";
      repo = "beszel";
      tag = "v${version}";
      hash = "sha256-tAi48PAHDGIZn/HMsnCq0mLpvFSqUOMocq47hooiFT8=";
    };
    vendorHash = "sha256-B6mOqOgcrRn0jV9wnDgRmBvfw7I/Qy5MNYvTiaCgjBE=";
  });
in {
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
      ExecStart = "${beszel-next}/bin/beszel-agent";
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
