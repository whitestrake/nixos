{
  description = "Whitestrake's NixOS Flake";

  nixConfig = {
    extra-substituters = [
      "https://cache.garnix.io"
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
      "https://whitestrake.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "whitestrake.cachix.org-1:UYcyluINGeeyAQgGOrEmOarylMNU5kLMagM0nXOkQK8="
    ];
  };

  inputs = {
    # Nix packages
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # https://github.com/nix-community/home-manager
    home-manager.url = "github:nix-community/home-manager/release-25.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/LnL7/nix-darwin
    nix-darwin.url = "github:LnL7/nix-darwin/nix-darwin-25.05";
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
    mkNode = name: domain: {
      hostname = "${name}.${domain}";
      profiles.system.path = deploy-rs.lib.${self.nixosConfigurations.${name}.pkgs.system}.activate.nixos self.nixosConfigurations.${name};
    };
    mkDeploy = nodes: {
      user = "root";
      sshUser = "whitestrake";
      sshOpts = ["-A"];
      inherit nodes;
    };

    # List of nodes we want to deploy to
    deployableNodes =
      builtins.mapAttrs (name: domain: mkNode name domain) {
        # brutus = "fell-monitor.ts.net";
        pascal = "fell-monitor.ts.net";
        rapier = "fell-monitor.ts.net";
        sortie = "fell-monitor.ts.net";

        orthus = "fell-monitor.ts.net";
        oculus = "fell-monitor.ts.net";
        omnius = "fell-monitor.ts.net";
      }
      // {
        jaeger = {
          # Split out so this host can build its own system. Cross compiling is too slow.
          hostname = "jaeger.fell-monitor.ts.net";
          remoteBuild = true;
          interactiveSudo = true;
          profiles.system.path = deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations.jaeger;
        };
      };

    # Separates the deployable nodes out by their system
    nodesBySystem = builtins.foldl' (
      acc: nodeName: let
        node = deployableNodes.${nodeName};
        system = self.nixosConfigurations.${nodeName}.pkgs.system;
      in
        acc // {${system} = (acc.${system} or {}) // {${nodeName} = node;};}
    ) {} (builtins.attrNames deployableNodes);

    # For each distinct system, create the deploy checks only for that system's nodes;
    # this ensures that deploy-rs does not cross-contaminate checks between different
    # architectures, letting the deployer do relevant checks instead of skipping or failing
    checks = builtins.mapAttrs (system: nodes: deploy-rs.lib.${system}.deployChecks (mkDeploy nodes)) nodesBySystem;

    # Add the combined deploy object without separation for CLI use
    deploy = mkDeploy deployableNodes;
  in {
    nixosConfigurations = builtins.mapAttrs (name: system: mkSystem nixpkgs.lib.nixosSystem name system) {
      brutus = "x86_64-linux"; # LXC
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

    inherit deploy checks;
  };
}
