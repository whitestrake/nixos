{den, ...}: {
  den.aspects.andred = {
    includes = [
      den.aspects.darwin
      den.aspects.nix-tools
    ];

    darwin = {pkgs, ...}: {
      system.stateVersion = 4;
      system.primaryUser = "whitestrake";
      programs.zsh.enable = true;
    };
  };
}
