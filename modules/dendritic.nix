{
  inputs,
  config,
  ...
}: {
  flake-file = {
    description = "Whitestrake's Dendritic Nix OS configuration";

    nixConfig = with builtins; {
      lazy-trees = true;
      extra-substituters = catAttrs "url" (attrValues config.caches);
      extra-trusted-public-keys = catAttrs "key" (attrValues config.caches);
    };

    inputs = {
      den.url = "github:vic/den";
      disko = {
        url = "github:nix-community/disko/latest";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      flake-file.url = "github:denful/flake-file";
      flake-parts = {
        url = "github:hercules-ci/flake-parts";
        inputs.nixpkgs-lib.follows = "nixpkgs";
      };
      import-tree.url = "github:vic/import-tree";
      nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
      nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
      nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
      darwin = {
        url = "github:LnL7/nix-darwin/nix-darwin-26.05";
        inputs.nixpkgs.follows = "nixpkgs-darwin";
      };
      home-manager = {
        url = "github:nix-community/home-manager/release-26.05";
        inputs.nixpkgs.follows = "nixpkgs";
      };
    };
  };

  systems = builtins.attrNames config.den.hosts;

  imports = [
    (inputs.flake-file.flakeModules.dendritic or {})
    (inputs.den.flakeModules.dendritic or inputs.den.flakeModule)
    (inputs.den.namespace "whitestrake" true)
  ];
}
