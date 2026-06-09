{inputs, ...}: {
  flake-file.inputs.vscode-server = {
    url = "github:nix-community/nixos-vscode-server";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.aspects.vscode-server = {
    nixos = {...}: {
      imports = [inputs.vscode-server.nixosModules.default];
      services.vscode-server.enable = true;
    };
  };
}
