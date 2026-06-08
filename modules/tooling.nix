{...}: let
  mkTooling = {
    pkgs,
    system,
  }: let
    repoPackages = with pkgs; [
      alejandra
      nil
      actionlint
      yamlfmt
    ];
  in {
    inherit repoPackages;
    formatter = pkgs.alejandra;
    operatorPackages =
      repoPackages
      ++ (with pkgs; [
        sops
        age
        deploy-rs
        nixos-rebuild
        nix-update
        rbw
      ]);
  };
in {
  _module.args.mkTooling = mkTooling;

  perSystem = {
    pkgs,
    system,
    ...
  }: let
    tooling = mkTooling {inherit pkgs system;};
  in {
    formatter = tooling.formatter;

    devShells.default = pkgs.mkShell {
      packages = tooling.repoPackages;
    };
  };
}
