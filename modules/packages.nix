{inputs, ...}: {
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
}
