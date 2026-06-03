{...}: {
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
    };
  };
}
