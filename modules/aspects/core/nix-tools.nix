{inputs, ...}: let
  sharedPackages = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      sops
      age
      deploy-rs
      nix-update
      nix-inspect
      nil
      alejandra
      actionlint
      yamlfmt
    ];
    environment.shellAliases.deploy-rs-async = let
      deploy-rs-async = inputs.deploy-rs-async.packages.${pkgs.stdenv.hostPlatform.system}.deploy-rs;
    in "${deploy-rs-async}/bin/deploy --remote-build";
  };
in {
  den.aspects.nix-tools = {
    nixos = {
      imports = [sharedPackages];
    };

    darwin = {pkgs, ...}: {
      imports = [sharedPackages];
      environment.systemPackages = with pkgs; [nixos-rebuild];
    };
  };
}
