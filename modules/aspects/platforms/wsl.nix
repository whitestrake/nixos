{den, ...}: {
  flake-file.inputs.nixos-wsl = {
    url = "github:nix-community/NixOS-WSL/main";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.aspects.wsl = {
    nixos = {pkgs, ...}: {
      # Allow running non-Nix dynamic binaries
      programs.nix-ld.enable = true;

      # WSL packages
      environment.systemPackages = with pkgs; [
        powershell
      ];
    };
  };
}
