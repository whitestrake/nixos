{
  lib,
  self,
  ...
}: let
  mkDeploymentTarget = name: cfg: let
    system = cfg.pkgs.stdenv.hostPlatform.system;
  in {
    inherit system;
    storePath = toString cfg.config.system.build.toplevel;
    rollbackScript = toString self.packages.${system}.deploy-health-rollback-script;
    deployPin = "deployed-host-${name}";
  };
in {
  flake.deploy.targets =
    lib.mapAttrs mkDeploymentTarget
    (lib.filterAttrs
      (_: cfg: cfg.config.services.cachix-agent.enable or false)
      (self.nixosConfigurations or {}));
}
