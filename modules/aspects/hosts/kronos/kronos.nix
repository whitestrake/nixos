{den, ...}: {
  den.aspects.kronos = {
    includes = [
      den.aspects.dev-tools
    ];

    nixos = {
      environment.etc."ci-experiment-e35".text = "PR158 E35 publication probe 2026-09-06 5ad118a\n";
      system.stateVersion = "25.11";
    };
  };
}
