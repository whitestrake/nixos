{inputs, ...}: let
  sharedPackages = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      sops
      age
      deploy-rs
      nix-update
      nix-inspect
      nil
      alejandra
      actionlint
      yamlfmt
      rbw
    ];
    environment.shellAliases.deploy-rs-async = let
      deploy-rs-async = inputs.deploy-rs-async.packages.${pkgs.stdenv.hostPlatform.system}.deploy-rs;
    in "${deploy-rs-async}/bin/deploy --remote-build";
  };

  sharedHomeManager = {
    config,
    lib,
    osConfig ? {},
    ...
  }: {
    programs.gh = {
      enable = true;
      gitCredentialHelper = {
        enable = true;
      };
    };

    home.file = lib.mkIf (osConfig ? sops) {
      ".config/gh/hosts.yml".source = config.lib.file.mkOutOfStoreSymlink osConfig.sops.templates."gh-hosts".path;
    };
  };

  nixTools = {
    nixos = {config, ...}: {
      imports = [sharedPackages];

      sops.secrets.githubToken = {};
      sops.templates."gh-hosts" = {
        content = ''
          github.com:
            oauth_token: ''${config.sops.placeholder.githubToken}
            git_protocol: https
            user: whitestrake
        '';
        owner = "whitestrake";
      };

      home-manager.users.whitestrake = sharedHomeManager;
    };

    darwin = {pkgs, ...}: {
      imports = [sharedPackages];
      environment.systemPackages = with pkgs; [nixos-rebuild];

      home-manager.users.whitestrake = sharedHomeManager;
    };
  };
in {
  den.ful.whitestrake.nix-tools = nixTools;
  den.aspects.nix-tools = nixTools;
}
