{ den, inputs, ... }: {
  den.aspects.user-whitestrake = {
    includes = [ den.provides.define-user den.provides.primary-user ];

    nixos = { config, pkgs, ... }: {
      sops.secrets.whitestrakePassword.neededForUsers = true;
      users.users.whitestrake = {
        isNormalUser = true;
        hashedPasswordFile = config.sops.secrets.whitestrakePassword.path;
        extraGroups = ["wheel" "docker" "www-data" "mediaserver"];
        shell = pkgs.fish;
        openssh.authorizedKeys.keyFiles = [inputs.whitestrake-github-keys.outPath];
      };
      programs.git.enable = true;
    };

    darwin = { pkgs, ... }: {
      users.users.whitestrake = {
        shell = pkgs.fish;
        home = "/Users/whitestrake";
      };
    };

    homeManager = { pkgs, lib, ... }: {
      imports = [ ../../../users/whitestrake/home.nix ];

      home.sessionVariables = lib.mkMerge [
        { CLICOLOR = "1"; }
        (lib.mkIf pkgs.stdenv.isDarwin { EDITOR = "antigravity"; })
      ];

      home.shellAliases = lib.mkIf pkgs.stdenv.isDarwin {
        tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
        agy = "/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity";
      };
    };
  };
}
