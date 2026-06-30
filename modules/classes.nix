# Declares repo-specific Den classes and routing policies.
# Default payloads for these classes belong in modules/defaults.nix.
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
  den.classes.hmLinux.description = "Linux-only Home Manager configuration";
  den.classes.hmDarwin.description = "Darwin-only Home Manager configuration";

  den.batteries.hmPlatforms = {
    host,
    user,
    ...
  }:
    den.batteries.forward {
      each = ["Linux" "Darwin"];
      fromClass = platform: "hm${platform}";
      intoClass = _: "homeManager";
      intoPath = _: [];
      fromAspect = _: den.lib.resolveEntity "user" {inherit host user;};
      guard = {pkgs, ...}: platform: lib.mkIf pkgs.stdenv."is${platform}";
      adaptArgs = {config, ...}: {osConfig = config;};
    };

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

  den.schema.host.includes = [den.policies.wsl-host-to-host];
  den.schema.user.includes = [den.batteries.hmPlatforms];
}
