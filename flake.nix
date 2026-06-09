{
  description = "Whitestrake's Dendritic Nix OS configuration";

  nixConfig = {
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
    # Nix packages
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Home manager
    home-manager.url = "github:nix-community/home-manager/release-25.11";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # macOS (nix-darwin)
    darwin.url = "github:LnL7/nix-darwin/nix-darwin-25.11";
    darwin.inputs.nixpkgs.follows = "nixpkgs";

    # NixOS WSL
    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    # Deployment
    deploy-rs.url = "github:serokell/deploy-rs";
    deploy-rs.inputs.nixpkgs.follows = "nixpkgs";
    deploy-rs-async.url = "github:serokell/deploy-rs/refs/pull/271/merge";

    # Secrets
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # vscode-server
    vscode-server.url = "github:nix-community/nixos-vscode-server";
    vscode-server.inputs.nixpkgs.follows = "nixpkgs";

    # disko
    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # Intel GPU SR-IOV
    i915-sriov.url = "github:strongtz/i915-sriov-dkms/2026.03.05.2";
    i915-sriov.inputs.nixpkgs.follows = "nixpkgs-unstable";

    # User keys
    whitestrake-github-keys.url = "https://github.com/whitestrake.keys";
    whitestrake-github-keys.flake = false;

    # Den framework
    den.url = "github:vic/den";

    # flake-file
    flake-file.url = "github:denful/flake-file";

    # flake-parts
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    # import-tree
    import-tree.url = "github:vic/import-tree";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;}
    ({...}: {
      _module.args.flakeRoot = ./.;
      imports = [(inputs.import-tree ./modules)];
    });
}
