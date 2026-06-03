{
  self,
  lib,
  ...
}: {
  flake = {
    # CI target for nix-fast-build
    ci = {
      # 1. NixOS Configurations (system toplevel derivations)
      nixos = lib.mapAttrs (name: conf: conf.config.system.build.toplevel) self.nixosConfigurations;

      # 2. Darwin Configurations (system derivations)
      darwin = lib.mapAttrs (name: conf: conf.system) self.darwinConfigurations;

      # 3. Custom packages across all systems
      packages = self.packages;

      # 4. Flake checks (excluding deploy-rs checks to avoid CI build duplication)
      checks = lib.mapAttrs (
        sys: sysChecks:
          lib.filterAttrs (name: _: !(lib.hasPrefix "deploy" name)) sysChecks
      ) (self.checks or {});
    };
  };
}
