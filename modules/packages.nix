{inputs, ...}: let
  pkgs = import inputs.nixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
  unstablePkgs = import inputs.nixpkgs-unstable {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
  packages = import ../pkgs {
    inherit pkgs unstablePkgs;
  };
  lib = pkgs.lib;
  hasLocalVersion = name: drv: let
    pos = builtins.unsafeGetAttrPos "version" drv;
    repoPath = toString ../.;
  in
    pos != null && lib.hasPrefix repoPath pos.file;
in {
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    packages = import ../pkgs {
      inherit pkgs;
      unstablePkgs = import inputs.nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
    };
  };

  flake.updatablePackages =
    builtins.sort builtins.lessThan
    (lib.attrNames
      (lib.filterAttrs hasLocalVersion packages));
}
