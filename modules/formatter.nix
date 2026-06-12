{inputs, ...}: {
  flake-file.inputs.treefmt-nix = {
    url = "github:numtide/treefmt-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  imports = [inputs.treefmt-nix.flakeModule];

  perSystem = {pkgs, ...}: {
    treefmt = {
      programs = {
        alejandra.enable = true;
        actionlint.enable = true;
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

      settings = {
        formatter.nil = {
          command = "${pkgs.nil}/bin/nil";
          options = ["diagnostics" "--deny-warnings"];
          includes = ["*.nix"];
          type = "check";
        };

        excludes = [
          "flake.nix"
          "modules/secrets/secrets.yaml"
        ];
      };
    };
  };
}
