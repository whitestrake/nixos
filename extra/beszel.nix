{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [../secrets];
  sops.secrets.beszelEnv = {};

  services.beszel.agent = {
    enable = lib.mkDefault true;
    environmentFile = config.sops.secrets.beszelEnv.path;
    # package = pkgs.unstable.beszel;
    package = pkgs.beszel.overrideAttrs (oldAttrs: rec {
      version = "0.17.0";
      src = pkgs.fetchFromGitHub {
        owner = "henrygd";
        repo = "beszel";
        tag = "v${version}";
        hash = "sha256-MY/rsWdIiYsqcw6gqDkfA8A/Ied3OSHfJI3KUBxoRKc=";
      };
      vendorHash = "sha256-gfQU3jGwTGmMJIy9KTjk/Ncwpk886vMo4CJvm5Y5xpA=";
    });
  };
  users.users.beszel-agent.isSystemUser = true;
  users.users.beszel-agent.group = "beszel-agent";
  users.groups.beszel-agent = {};
  systemd.services.beszel-agent.serviceConfig = {
    DynamicUser = lib.mkForce false;
    Group = "beszel-agent";
    SupplementaryGroups =
      ["messagebus"]
      ++ lib.optionals config.virtualisation.docker.enable ["docker"];
  };
}
