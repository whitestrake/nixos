{
  inputs,
  mkLocalPackages,
  ...
}: let
  localPackagesFor = pkgs: system:
    mkLocalPackages {
      inherit pkgs;
      unstablePkgs = import inputs.nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
    };

  # updatablePackages is currently based on x86_64-linux evaluation.
  # This is intentional as the GitHub Actions scheduled update workflow
  # uses this set for dynamic package-update discovery.
  x86_64-pkgs = import inputs.nixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
  packages = localPackagesFor x86_64-pkgs "x86_64-linux";

  lib = x86_64-pkgs.lib;
  hasLocalVersion = name: drv: let
    pos = builtins.unsafeGetAttrPos "version" drv;
    repoPath = toString ../.;
  in
    drv ? version
    && drv ? src
    && pos != null
    && lib.hasPrefix repoPath pos.file;
in {
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    packages = localPackagesFor pkgs system;
  };

  flake.updatablePackages =
    builtins.sort builtins.lessThan
    (lib.attrNames
      (lib.filterAttrs hasLocalVersion packages));
}
