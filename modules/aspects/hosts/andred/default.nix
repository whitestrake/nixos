{den, ...}: {
  den.aspects.andred = {
    includes = [
      den.aspects.darwin-base
    ];

    darwin = {pkgs, ...}: {
      system.stateVersion = 4;
      system.primaryUser = "whitestrake";

      environment.systemPackages = with pkgs; [
        age
        sops
        deploy-rs
        alejandra
        nixos-rebuild
        nix-update
        nix-inspect
        nil
      ];
    };
  };
}
