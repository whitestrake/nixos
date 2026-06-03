{
  self,
  lib,
  ...
}: {
  flake = {
    # CI targets grouped by architecture to facilitate parallel, matrixed builds on GitHub Actions
    ci = let
      supportedSystems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
      getConfigSystem = conf: conf.pkgs.system;
      nixosForSystem = sys: lib.filterAttrs (_: conf: getConfigSystem conf == sys) self.nixosConfigurations;
      darwinForSystem = sys: lib.filterAttrs (_: conf: getConfigSystem conf == sys) self.darwinConfigurations;
    in
      lib.genAttrs supportedSystems (sys: {
        # NixOS system toplevels for this architecture
        nixos = lib.mapAttrs (_: conf: conf.config.system.build.toplevel) (nixosForSystem sys);

        # Darwin system configurations for this architecture
        darwin = lib.mapAttrs (_: conf: conf.system) (darwinForSystem sys);

        # Custom packages built for this architecture
        packages = self.packages.${sys} or {};

        # Checks for this architecture (filtering out deploy-rs to prevent duplication)
        checks = lib.filterAttrs (name: _: !(lib.hasPrefix "deploy" name)) (self.checks.${sys} or {});
      });
  };
}
