{
  description = "Whitestrake's NixOS Flake";

  nixConfig = {
    extra-substituters = [
      "https://cache.garnix.io"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  inputs = {
    # Nix packages
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # https://github.com/nix-community/home-manager
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/LnL7/nix-darwin
    nix-darwin.url = "github:LnL7/nix-darwin/nix-darwin-25.11";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/nix-community/NixOS-WSL
    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/serokell/deploy-rs
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";

    deploy-rs-async.url = "github:serokell/deploy-rs/refs/pull/271/merge";
    deploy-rs-async.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/Mic92/sops-nix
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/nix-community/nixos-vscode-server
    vscode-server.url = "github:nix-community/nixos-vscode-server";
    vscode-server.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/nix-community/disko
    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/strongtz/i915-sriov-dkms
    i915-sriov.url = "github:strongtz/i915-sriov-dkms";
    i915-sriov.inputs.nixpkgs.follows = "nixpkgs-unstable";

    # Github SSH keys
    whitestrake-github-keys.url = "https://github.com/whitestrake.keys";
    whitestrake-github-keys.flake = false;

    # Add check_mk https://github.com/NixOS/nixpkgs/pull/399463
    check_mk-pr.url = "github:NixOS/nixpkgs?ref=pull/399463/head";
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    home-manager,
    nix-darwin,
    nixos-wsl,
    deploy-rs,
    deploy-rs-async,
    sops-nix,
    ...
  } @ inputs: let
    inherit (nixpkgs) lib;
    myLib = import ./lib;

    # Build a NixOS or Darwin system configuration
    # function: nixpkgs.lib.nixosSystem or nix-darwin.lib.darwinSystem
    # name: hostname, used to find ./hosts/${name} and as the config key
    # system: architecture string (e.g. "x86_64-linux")
    mkSystem = function: name: system:
      function {
        inherit system;
        specialArgs = {inherit inputs myLib;};
        modules = [
          ./hosts/${name}
          ./common/${system}.nix
        ];
      };

    # Build a deploy-rs node definition from a myNodes entry
    # Merges any host-specific deploy overrides (remoteBuild, interactiveSudo, etc.)
    mkNode = name: meta:
      {
        hostname = "${name}.fell-monitor.ts.net";
        profiles.system.path = deploy-rs.lib.${meta.system}.activate.nixos self.nixosConfigurations.${name};
      }
      // (meta.deploy or {});

    # Wrap nodes in deploy-rs top-level config with shared SSH settings
    mkDeploy = nodes: {
      user = "root";
      sshUser = "whitestrake";
      sshOpts = ["-A"];
      inherit nodes;
    };

    myNodes = {
      # PVE
      pascal = {system = "x86_64-linux";};
      rapier = {system = "x86_64-linux";};
      sortie = {system = "x86_64-linux";};

      # HH
      orthus = {system = "x86_64-linux";};
      oculus = {system = "x86_64-linux";};
      omnius = {system = "x86_64-linux";};

      # OCI
      jaeger = {
        system = "aarch64-linux";
        # deploy = {interactiveSudo = true;};
      };
    };

    # Filter out nodes with deploy = false
    deployableNodes = lib.filterAttrs (_: n: (n.deploy or true) != false) myNodes;
  in {
    nixosConfigurations = lib.mapAttrs (name: meta: mkSystem nixpkgs.lib.nixosSystem name meta.system) myNodes;

    darwinConfigurations = lib.mapAttrs (name: system: mkSystem nix-darwin.lib.darwinSystem name system) {
      andred = "aarch64-darwin"; # MBP
    };

    # Combined deploy object for CLI: `deploy`
    deploy = mkDeploy (lib.mapAttrs mkNode deployableNodes);

    # Per-system deploy checks for `nix flake check`
    #
    # The default recommended deploy-rs checks put ALL nodes under all systems,
    # regardless of their actual architecture. This causes `nix flake check` to
    # fail when it tries to evaluate aarch64 derivations on x86_64 (or vice
    # versa) without cross-compilation.
    #
    # To fix this, we group nodes by their system architecture and generate
    # separate deployChecks for each group:
    # 1. Extract unique systems from deployable nodes
    # 2. Group nodes by their system
    # 3. Generate deployChecks for each system's nodes only
    checks = let
      systems = lib.unique (lib.mapAttrsToList (_: n: n.system) deployableNodes);
      nodesBySystem = lib.genAttrs systems (
        system: lib.filterAttrs (_: meta: meta.system == system) deployableNodes
      );
    in
      lib.mapAttrs (
        system: systemNodes:
          deploy-rs.lib.${system}.deployChecks (mkDeploy (lib.mapAttrs mkNode systemNodes))
      )
      nodesBySystem;
  };
}
