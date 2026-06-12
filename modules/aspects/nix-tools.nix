{
  config,
  inputs,
  ...
}: {
  flake-file.inputs.deploy-rs-async.url = "github:serokell/deploy-rs/refs/pull/271/merge";

  den.aspects.nix-tools = {
    os = {pkgs, ...}: {
      environment.systemPackages = with pkgs; [
        alejandra
        nil
        actionlint
        yamlfmt
        mdformat
        sops
        age
        deploy-rs
        nixos-rebuild
        nix-update
      ];
      environment.shellAliases.deploy-rs-async = let
        system = pkgs.stdenv.hostPlatform.system;
        deploy-rs-async = inputs.deploy-rs-async.packages.${system}.deploy-rs;
      in "${deploy-rs-async}/bin/deploy --remote-build";
    };

    provides.whitestrake.nixos = {config, ...}: {
      sops.secrets.githubToken = {};
      sops.templates."gh-hosts" = {
        content = ''
          github.com:
            oauth_token: ${config.sops.placeholder.githubToken}
            git_protocol: https
            user: whitestrake
        '';
        owner = "whitestrake";
      };
    };

    provides.whitestrake.homeManager = {
      lib,
      config,
      osConfig ? {},
      ...
    }: {
      programs.gh = {
        enable = true;
        gitCredentialHelper.enable = true;
      };

      home.file = lib.mkIf (osConfig ? sops) {
        ".config/gh/hosts.yml".source =
          config.lib.file.mkOutOfStoreSymlink
          osConfig.sops.templates."gh-hosts".path;
      };
    };
  };

  # Export the aspect under a namespace
  den.ful.whitestrake.nix-tools = config.den.aspects.nix-tools;
}
