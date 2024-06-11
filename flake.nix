{
  description = "Whitestrake's NixOS Flake";

  nixConfig = {
    trusted-substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };

  inputs = {
    # Nix packages
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05-small";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # https://github.com/nix-community/home-manager
    home-manager.url = "github:nix-community/home-manager/release-24.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # https://github.com/LnL7/nix-darwin
    nix-darwin.url = "github:LnL7/nix-darwin";
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

    # Nil LSP
    nil.url = "github:oxalica/nil";

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
    ...
  } @ inputs: let
    mkSystem = function: system: name:
      function {
        inherit system;
        specialArgs = {inherit inputs;};
        modules = [./hosts ./hosts/${name}];
      };
  in {
    # NixOS machines
    nixosConfigurations = nixpkgs.lib.attrsets.genAttrs [
      "brutus"
      "charon"
      "ishtar"
      "omnius"
      "pascal"
    ] (name: mkSystem nixpkgs.lib.nixosSystem "x86_64-linux" name);

    # MacOS machines
    darwinConfigurations = nixpkgs.lib.attrsets.genAttrs [
      "andred"
    ] (name: mkSystem nix-darwin.lib.darwinSystem "aarch64-darwin" name);

    deploy = {
      user = "root";
      sshUser = "whitestrake";
      # interactiveSudo = true;
      # remoteBuild = true;

      nodes =
        nixpkgs.lib.attrsets.genAttrs [
          "brutus"
          "ishtar"
          "omnius"
          "pascal"
        ] (name: {
          hostname = "${name}.fell-monitor.ts.net";
          profiles.system.path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations."${name}";
        });
    };

    # This is highly advised, and will prevent many possible mistakes
    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
  };
}
