{
  den,
  lib,
  ...
}: {
  flake-file.inputs.nixos-wsl = {
    url = "github:nix-community/NixOS-WSL/main";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.classes.wsl-host.description = "Host-level NixOS configuration applied only to WSL hosts";

  den.policies.wsl-host-to-host = {host, ...}:
    lib.optional (
      host ? class
      && host.class == "nixos"
      && ((host.wsl or {}).enable or false)
    ) (
      den.lib.policy.route {
        fromClass = "wsl-host";
        intoClass = host.class;
        path = [];
      }
    );

  den.default.includes = [den.policies.wsl-host-to-host];
}
