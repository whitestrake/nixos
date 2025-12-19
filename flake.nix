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

    # GitLab SSH keys
    whitestrake-gitlab-keys.url = "https://gitlab.com/Whitestrake.keys";
    whitestrake-gitlab-keys.flake = false;

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
    sops-nix,
    ...
  } @ inputs: let
    # Helpers
    mkSystem = function: name: system:
      function {
        inherit system;
        specialArgs = {inherit inputs;};
        modules = [
          ./hosts/${name}
          ./common/${system}.nix
        ];
      };
    mkNode = name: overrides: let
      domain = "fell-monitor.ts.net";
      system = self.nixosConfigurations.${name}.pkgs.stdenv.hostPlatform.system;
      default = {
        hostname = "${name}.${domain}";
        profiles.system.path = deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.${name};
      };
    in
      default // overrides;
    mkDeploy = nodes: {
      user = "root";
      sshUser = "whitestrake";
      sshOpts = ["-A"];
      inherit nodes;
    };

    # Groups deployable nodes by their system architecture
    nodesBySystem = nodeList:
      builtins.foldl' (
        acc: nodeName: let
          node = nodeList.${nodeName};
          system = self.nixosConfigurations.${nodeName}.pkgs.stdenv.hostPlatform.system;
        in
          acc // {${system} = (acc.${system} or {}) // {${nodeName} = node;};}
      ) {} (builtins.attrNames nodeList);

    nodeNames = [
      # "brutus" # LXC
      "pascal" # PVE
      "rapier" # PVE
      "sortie" # PVE

      "orthus" # HH
      "oculus" # HH
      "omnius" # HH

      "jaeger" # OCI
    ];
    nodeOverrides = {
      jaeger = {
        remoteBuild = true;
        interactiveSudo = true;
      };
    };
    deployableNodes = builtins.listToAttrs (map (name: {
        name = name;
        value = mkNode name (nodeOverrides.${name} or {});
      })
      nodeNames);
  in {
    nixosConfigurations = builtins.mapAttrs (name: system: mkSystem nixpkgs.lib.nixosSystem name system) {
      # brutus = "x86_64-linux"; # LXC
      pascal = "x86_64-linux"; # PVE
      rapier = "x86_64-linux"; # PVE
      sortie = "x86_64-linux"; # PVE

      orthus = "x86_64-linux"; # HH
      oculus = "x86_64-linux"; # HH
      omnius = "x86_64-linux"; # HH

      jaeger = "aarch64-linux"; # OCI
    };

    darwinConfigurations = builtins.mapAttrs (name: system: mkSystem nix-darwin.lib.darwinSystem name system) {
      andred = "aarch64-darwin"; # MBP
    };

    # For each distinct system, create the deploy checks only for that system's nodes;
    # this ensures that deploy-rs does not cross-contaminate checks between different
    # architectures, letting the deployer do relevant checks instead of skipping or failing
    checks = builtins.mapAttrs (system: nodes: deploy-rs.lib.${system}.deployChecks (mkDeploy nodes)) nodesBySystem;

    # Add the combined deploy object without system separation for CLI use
    deploy = mkDeploy deployableNodes;
  };
}
