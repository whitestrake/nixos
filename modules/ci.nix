{
  lib,
  self,
  ...
}: let
  toplevels =
    lib.mapAttrs
    (_: configuration: configuration.config.system.build.toplevel);
  deploymentSystems =
    lib.unique
    (lib.mapAttrsToList
      (_: target: target.system)
      self.deploy.targets);
  rollbackScripts =
    builtins.listToAttrs
    (map
      (system:
        lib.nameValuePair
        "deploy-health-rollback-script-${system}"
        self.packages.${system}.deploy-health-rollback-script)
      deploymentSystems);
  checks =
    {
      check-flake-file = self.checks.x86_64-linux.check-flake-file;
      check-treefmt = self.checks.x86_64-linux.treefmt;
    }
    // builtins.listToAttrs
    (map
      (system:
        lib.nameValuePair
        "check-deploy-health-rollback-script-${system}"
        self.checks.${system}.validate-deploy-health-rollback-script)
      deploymentSystems);
in {
  flake.ci = {
    linux = toplevels self.nixosConfigurations // rollbackScripts // checks;
    darwin = toplevels self.darwinConfigurations;
  };
}
