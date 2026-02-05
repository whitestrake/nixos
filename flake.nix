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

    # PR to add support for async build and deploy
    deploy-rs-async.url = "github:serokell/deploy-rs/refs/pull/271/merge";

    # https://github.com/Mic92/sops-nix
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/nix-community/nixos-vscode-server
    vscode-server.url = "github:nix-community/nixos-vscode-server";
    vscode-server.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/zhaofengli/attic
    attic.url = "github:zhaofengli/attic";

    # https://github.com/nix-community/disko
    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/strongtz/i915-sriov-dkms
    i915-sriov.url = "github:strongtz/i915-sriov-dkms";
    i915-sriov.inputs.nixpkgs.follows = "nixpkgs-unstable";

    # Github SSH keys
    whitestrake-github-keys.url = "https://github.com/whitestrake.keys";
    whitestrake-github-keys.flake = false;
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

    # Build a NixOS or Darwin system configuration
    # function: nixpkgs.lib.nixosSystem or nix-darwin.lib.darwinSystem
    # name: hostname, used to find ./hosts/${name} and as the config key
    # meta: node metadata (system, isServer, etc.)
    mkSystem = function: name: meta:
      function {
        inherit (meta) system;
        specialArgs = {
          inherit inputs meta;
          unstable = unstablePkgs.${meta.system};
          lib = lib.extend (final: prev: import ./lib);
        };
        modules = [
          ./hosts/${name}
          ./common/${meta.system}.nix
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

    nixosNodes = {
      # PVE
      pascal = {system = "x86_64-linux";};
      rapier = {system = "x86_64-linux";};
      sortie = {system = "x86_64-linux";};

      # HH
      orthus = {system = "x86_64-linux";};
      oculus = {system = "x86_64-linux";};
      omnius = {system = "x86_64-linux";};

      # OCI
      jaeger = {system = "aarch64-linux";};

      # WSL
      kronos = {
        system = "x86_64-linux";
        isServer = false;
      };
    };

    darwinNodes = {
      andred = {system = "aarch64-darwin";}; # MBP
    };

    # Filter out nodes with deploy or isServer = false
    deployableNodes = lib.filterAttrs (_: n: n.deploy or (n.isServer or true)) nixosNodes;

    # Extract unique systems from nodes for package/check generation
    systems = lib.unique (lib.mapAttrsToList (_: n: n.system) (nixosNodes // darwinNodes));

    # Instantiate unstable nixpkgs for each system once, to be passed to modules
    unstablePkgs = lib.genAttrs systems (system:
      import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      });
  in {
    # NixOS Linux hosts
    nixosConfigurations = lib.mapAttrs (mkSystem nixpkgs.lib.nixosSystem) nixosNodes;

    # Darwin MacOS hosts
    darwinConfigurations = lib.mapAttrs (mkSystem nix-darwin.lib.darwinSystem) darwinNodes;

    # Output for deploy-rs cli
    deploy = mkDeploy (lib.mapAttrs mkNode deployableNodes);

    # Expose our custom packages for nix-update ease of use
    packages = lib.genAttrs systems (system: import ./pkgs {pkgs = nixpkgs.legacyPackages.${system};});

    # Per-system deploy checks for `nix flake check`
    # Group nodes by system architecture to avoid cross-compilation failures
    checks = lib.genAttrs systems (system:
      deploy-rs.lib.${system}.deployChecks (mkDeploy (
        lib.mapAttrs mkNode (lib.filterAttrs (_: n: n.system == system) deployableNodes)
      )));

    # CI target for nix-fast-build
    ci = lib.mapAttrs (name: conf: conf.config.system.build.toplevel) self.nixosConfigurations // self.packages.x86_64-linux // self.checks.x86_64-linux;
  };
}
