{
  den,
  inputs,
  ...
}: {
  flake-file.inputs.nixos-wsl = {
    url = "github:nix-community/NixOS-WSL/main";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.aspects.wsl-base = {
    includes = [
      den.aspects.common
    ];

    nixos = {pkgs, ...}: {
      imports = [
        inputs.nixos-wsl.nixosModules.default
      ];

      wsl.enable = true;

      # Allow running non-Nix dynamic binaries
      programs.nix-ld.enable = true;

      # nh CLI helper for NixOS
      programs.nh = {
        enable = true;
        flake = "github:whitestrake/nixos";
        clean = {
          enable = true;
          dates = "daily";
          extraArgs = "--keep-since 7d --keep 5";
        };
      };

      # WSL packages
      environment.systemPackages = with pkgs; [
        powershell
      ];
    };
  };
}
