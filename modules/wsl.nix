{
  den,
  lib,
  ...
}: let
  isWslHost = host:
    host ? class
    && host.class == "nixos"
    && ((host.wsl or {}).enable or false);
in {
  flake-file.inputs.nixos-wsl = {
    url = "github:nix-community/NixOS-WSL/main";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.default = {
    excludes = [den.policies.wsl-to-host];
    includes = [
      (
        {
          host,
          aspect-chain,
          ...
        }:
          lib.optionalAttrs (isWslHost host) (
            den.batteries.forward {
              each = lib.singleton true;
              fromClass = _: "wsl";
              intoClass = _: host.class;
              intoPath = _: ["wsl"];
              fromAspect = _: lib.head aspect-chain;
              guard = {options, ...}: options ? wsl;
            }
          )
      )
    ];

    nixos = {
      config,
      pkgs,
      lib,
      ...
    }:
      lib.mkIf (config.wsl.enable or false) {
        environment.systemPackages = with pkgs; [
          powershell
        ];
      };
  };
}
