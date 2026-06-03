{inputs, ...}: {
  den.aspects.nix-tools = {
    nixos = {pkgs, ...}: {
      environment.systemPackages = with pkgs; [
        sops
        age
        deploy-rs
        nix-update
        nix-inspect
        nil
        alejandra
      ];
      environment.shellAliases.deploy-rs-async = let
        deploy-rs-async = inputs.deploy-rs-async.packages.${pkgs.stdenv.hostPlatform.system}.deploy-rs;
      in "${deploy-rs-async}/bin/deploy --remote-build";
    };

    darwin = {pkgs, ...}: {
      environment.systemPackages = with pkgs; [
        sops
        age
        deploy-rs
        nix-update
        nix-inspect
        nil
        alejandra
        nixos-rebuild
      ];
      environment.shellAliases.deploy-rs-async = let
        deploy-rs-async = inputs.deploy-rs-async.packages.${pkgs.stdenv.hostPlatform.system}.deploy-rs;
      in "${deploy-rs-async}/bin/deploy --remote-build";
    };
  };
}
