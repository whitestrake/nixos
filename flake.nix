{
  description = "Whitestrake's NixOS Flake";

  nixConfig = {
    extra-substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };

  inputs = {
    # Nix packages
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11-small";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # https://github.com/nix-community/home-manager
    home-manager.url = "github:nix-community/home-manager/release-24.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/LnL7/nix-darwin
    nix-darwin.url = "github:LnL7/nix-darwin/nix-darwin-24.11";
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

    # https://github.com/oxalica/nil/issues/113
    nil.url = "github:oxalica/nil";

    # https://github.com/ToyVo/nh_plus
    nh_plus.url = "github:ToyVo/nh_plus";

    # Github SSH keys
    whitestrake-github-keys.url = "https://github.com/whitestrake.keys";
    whitestrake-github-keys.flake = false;

    # GitLab SSH keys
    whitestrake-gitlab-keys.url = "https://gitlab.com/Whitestrake.keys";
    whitestrake-gitlab-keys.flake = false;
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
    nil,
    nh_plus,
    ...
  } @ inputs: let
    mkSystem = function: name: system:
      function {
        inherit system;
        specialArgs = {inherit inputs;};
        modules = [
          ./hosts/${name}
          ./common/${system}.nix
        ];
      };
    mkDeployNixos = name: domain: {
      hostname = "${name}.${domain}";
      profiles.system.path = deploy-rs.lib.${self.nixosConfigurations.${name}.pkgs.system}.activate.nixos self.nixosConfigurations.${name};
    };
  in {
    # NixOS machines
    nixosConfigurations = builtins.mapAttrs (name: system: mkSystem nixpkgs.lib.nixosSystem name system) {
      brutus = "x86_64-linux"; # LXC
      charon = "x86_64-linux"; # WSL
      ishtar = "x86_64-linux"; # VPS
      orthus = "x86_64-linux"; # VPS
      pascal = "x86_64-linux"; # PVE
      jaeger = "aarch64-linux"; # OCI
    };

    # MacOS machines
    darwinConfigurations = builtins.mapAttrs (name: system: mkSystem nix-darwin.lib.darwinSystem name system) {
      andred = "aarch64-darwin"; # MBP
    };

    deploy = {
      user = "root";
      sshUser = "whitestrake";
      sshOpts = ["-A"];
      nodes = builtins.mapAttrs (name: domain: mkDeployNixos name domain) {
        brutus = "fell-monitor.ts.net";
        ishtar = "fell-monitor.ts.net";
        orthus = "fell-monitor.ts.net";
        pascal = "fell-monitor.ts.net";
        jaeger = "fell-monitor.ts.net";
      };
    };

    # This is highly advised, and will prevent many possible mistakes
    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
  };
}
