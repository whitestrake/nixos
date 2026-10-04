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
      den.url = "github:denful/den";
      disko = {
        url = "github:nix-community/disko/latest";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      flake-file.url = "github:denful/flake-file";
      # flake-parts only needs nixpkgs.lib, but flake-file defaults its
      # nixpkgs-lib input to follow nixpkgs, which made every darwin eval
      # fetch the full nixos-26.05 tree as well as nixpkgs-darwin. Point it at
      # flake-parts' own lib-only default instead (a few hundred KB).
      flake-parts = {
        url = "github:hercules-ci/flake-parts";
        inputs.nixpkgs-lib.follows = "nixpkgs-lib";
      };
      nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";
      # den loads gen-schema through the gen hub: this input when declared,
      # otherwise its own CI pin via builtins.fetchTree, which Nix never
      # substitutes from a binary cache. A lock-file input is substitutable,
      # so stores without GitHub API access can still evaluate this flake.
      gen = {
        url = "github:sini/gen";
        inputs.import-tree.follows = "import-tree";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      import-tree.url = "github:denful/import-tree";
      nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
      nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
      nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
      # nixos-unstable only waits on Linux builds, so its darwin outputs are often
      # uncached; darwin hosts take unstable packages from the Hydra-gated branch.
      nixpkgs-unstable-darwin.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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
