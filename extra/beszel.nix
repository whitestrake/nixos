{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  imports = [../secrets];
  sops.secrets.beszelEnv = {};

  services.beszel.agent = {
    enable = lib.mkDefault true;
    environmentFile = config.sops.secrets.beszelEnv.path;
    package = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.beszel;
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
