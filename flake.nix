# DO-NOT-EDIT. This file was auto-generated using github:vic/flake-file.
# Use `nix run .#write-flake` to regenerate it.
{
  description = "Whitestrake's Dendritic Nix OS configuration";

  outputs = inputs: inputs.flake-parts.lib.mkFlake {inherit inputs;} (inputs.import-tree ./modules);

  nixConfig = {
    extra-substituters = [
      "https://whitestrake.cachix.org?priority=50"
      "https://cache.garnix.io?priority=51"
      "https://nix-community.cachix.org?priority=41"
    ];
    extra-trusted-public-keys = [
      "whitestrake.cachix.org-1:UYcyluINGeeyAQgGOrEmOarylMNU5kLMagM0nXOkQK8="
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    lazy-trees = true;
  };

  inputs = {
    darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    den.url = "github:vic/den";
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs-async.url = "github:serokell/deploy-rs/refs/pull/271/merge";
    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-file.url = "github:denful/flake-file";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    i915-sriov = {
      url = "github:strongtz/i915-sriov-dkms/2026.03.05.2";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    import-tree.url = "github:vic/import-tree";
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    whitestrake-github-keys = {
      url = "https://github.com/whitestrake.keys";
      flake = false;
    };
  };
}
