{ den, ... }: {
  den.aspects.andred = {
    includes = [
      den.provides.hostname
      den.aspects.darwin-base
    ];

    darwin = { pkgs, ... }: {
      networking.hostName = "andred";
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
