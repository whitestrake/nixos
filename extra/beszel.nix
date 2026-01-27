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
    package = pkgs.myPkgs.beszel;
  };

  users.users.beszel-agent.isSystemUser = true;
  users.users.beszel-agent.group = "beszel-agent";
  users.groups.beszel-agent = {};

  systemd.services.beszel-agent = {
    environment.SYSTEM_NAME =
      lib.mkDefault (lib.strings.toSentenceCase config.networking.hostName);
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      Group = "beszel-agent";
      SupplementaryGroups =
        ["messagebus"]
        ++ lib.optionals config.virtualisation.docker.enable ["docker"];
    };
  };
}
