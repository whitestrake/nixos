{
  den,
  lib,
  ...
}: {
  den.schema.user.classes = lib.mkDefault ["homeManager"];

  # Base overrides applied globally to classes
  den.default = {
    includes = [
      den.provides.hostname
    ];

    nixos = {
      pkgs,
      lib,
      ...
    }: {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;

      system.stateVersion = lib.mkDefault "24.05";
      nixpkgs.config.allowUnfree = true;
      time.timeZone = lib.mkDefault "Australia/Brisbane";
      networking.domain = lib.mkDefault "whitestrake.net";
      documentation.nixos.enable = false;
      programs.nh = {
        enable = true;
        flake = "github:whitestrake/nixos";
        clean = {
          enable = true;
          dates = "daily";
          extraArgs = "--keep-since 7d --keep 5";
        };
      };
    };

    darwin = {
      pkgs,
      lib,
      ...
    }: {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;

      system.stateVersion = lib.mkDefault 4;
      nixpkgs.config.allowUnfree = true;
    };

    homeManager = {
      pkgs,
      lib,
      ...
    }: {
      home.stateVersion = lib.mkDefault "25.11";
      manual.html.enable = false;
      manual.manpages.enable = false;
      manual.json.enable = false;
    };
  };
}
