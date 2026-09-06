{den, ...}: {
  den.aspects.kronos = {
    includes = [
      den.aspects.dev-tools
    ];

    nixos = {
      system.stateVersion = "25.11";
    };
  };
}
