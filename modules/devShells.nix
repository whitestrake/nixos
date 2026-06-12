{...}: {
  perSystem = {
    config,
    pkgs,
    system,
    ...
  }: {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        alejandra
        nil
        actionlint
        yamlfmt
        mdformat
        config.treefmt.build.wrapper
      ];
    };
  };
}
