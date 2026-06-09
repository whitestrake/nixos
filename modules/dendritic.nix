{
  inputs,
  lib,
  ...
}: {
  _module.args.flakeRoot = lib.mkDefault ../.;

  flake-file = {
    description = "Whitestrake's Dendritic Nix OS configuration";

    nixConfig = {
      lazy-trees = true;
      extra-substituters = [
        "https://whitestrake.cachix.org?priority=10"
        "https://cache.garnix.io?priority=50"
        "https://nix-community.cachix.org?priority=60"
      ];
      extra-trusted-public-keys = [
        "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "whitestrake.cachix.org-1:UYcyluINGeeyAQgGOrEmOarylMNU5kLMagM0nXOkQK8="
      ];
    };

    inputs = {
      den.url = "github:vic/den";
      flake-file.url = "github:denful/flake-file";
      flake-parts = {
        url = "github:hercules-ci/flake-parts";
        inputs.nixpkgs-lib.follows = "nixpkgs";
      };
      import-tree.url = "github:vic/import-tree";
      nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
      nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
      darwin = {
        url = "github:LnL7/nix-darwin/nix-darwin-25.11";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      home-manager = {
        url = "github:nix-community/home-manager/release-25.11";
        inputs.nixpkgs.follows = "nixpkgs";
      };
    };
  };

  imports = [
    (inputs.flake-file.flakeModules.dendritic or {})
    (inputs.den.flakeModules.dendritic or inputs.den.flakeModule)
    (inputs.den.namespace "whitestrake" true)
  ];
}
