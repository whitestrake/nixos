{
  inputs,
  lib,
  ...
}: let
  mkTooling = {
    pkgs,
    system,
  }: let
    repoPackages = with pkgs; [
      alejandra
      nil
      actionlint
      yamlfmt
      mdformat
    ];
  in {
    inherit repoPackages;
    operatorPackages =
      repoPackages
      ++ (with pkgs; [
        sops
        age
        deploy-rs
        nixos-rebuild
        nix-update
        rbw
      ]);
  };
in {
  _module.args.mkTooling = mkTooling;

  flake-file.inputs.treefmt-nix = {
    url = "github:numtide/treefmt-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  imports = [
    (inputs.treefmt-nix.flakeModule or {})
  ];

  perSystem = {
    config,
    pkgs,
    system,
    ...
  }: let
    tooling = mkTooling {inherit pkgs system;};
  in
    {
      devShells.default = pkgs.mkShell {
        packages =
          tooling.repoPackages
          ++ lib.optionals (inputs ? treefmt-nix) [
            config.treefmt.build.wrapper
          ];
      };
    }
    // lib.optionalAttrs (inputs ? treefmt-nix) {
      treefmt = {
        programs = {
          alejandra.enable = true;
          yamlfmt = {
            enable = true;
            settings.formatter = {
              type = "basic";
              retain_line_breaks = true;
              scan_folded_as_literal = true;
              eof_newline = true;
            };
          };
          mdformat = {
            enable = true;
            settings.wrap = "keep";
          };
        };

        settings.excludes = [
          "flake.nix"
          "secrets/secrets.yaml"
        ];
      };
    };
}
