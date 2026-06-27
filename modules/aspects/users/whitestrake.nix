{
  den,
  inputs,
  config,
  ...
}: {
  flake-file.inputs.whitestrake-github-keys = {
    url = "https://github.com/whitestrake.keys";
    flake = false;
  };

  den.aspects.whitestrake = {
    includes = [
      den.provides.define-user
      den.provides.primary-user
      (den.provides.user-shell "zsh")
    ];

    provides.to-hosts.os.nix.settings.trusted-users = ["whitestrake"];
    provides.to-hosts.darwin = {pkgs, ...}: {
      environment.shells = with pkgs; [zsh fish];
      homebrew.enableZshIntegration = true;
    };

    nixos = {config, ...}: {
      sops.secrets.whitestrakePassword.neededForUsers = true;
      users.users.whitestrake = {
        hashedPasswordFile = config.sops.secrets.whitestrakePassword.path;
        extraGroups = ["docker" "www-data" "mediaserver"];
        openssh.authorizedKeys.keyFiles = [inputs.whitestrake-github-keys.outPath];
      };
    };

    homeManager = {
      config,
      pkgs,
      lib,
      ...
    }: {
      home.stateVersion = "23.11";
      home.sessionVariables = {
        COMPOSE_IGNORE_ORPHANS = "True";
        EDITOR = lib.mkDefault "hx";
        BAT_PAGING = "never";
        BAT_THEME = "TwoDark";
        CLICOLOR = "1";
      };

      home.shellAliases = {
        l = "eza --long --git-ignore";
        la = "eza --long --all --all --time-style=long-iso";
        df = "df -h -xtmpfs -xoverlay";
      };

      home.packages = with pkgs; [
        nix-search-cli
        nixos-rebuild
        ffmpeg
        yt-dlp
        bat
        rbw
        (writeShellApplication {
          name = "nrr";
          runtimeInputs = [nixos-rebuild];
          text = ''
            if [ "$#" -lt 1 ]; then
              echo "Usage: nrr HOST [COMMAND]" >&2
              exit 1
            fi

            host="$1"
            cmd="''${2:-switch}"

            NIX_SSHOPTS="-A" exec nixos-rebuild \
              --flake ".#$host" \
              --target-host "$host" \
              --build-host "$host" \
              --sudo "$cmd"
          '';
        })
      ];

      # Autojump
      programs.zoxide.enable = true;
      programs.zoxide.enableZshIntegration = true;
      programs.zoxide.options = ["--cmd j"];

      # Command-line fuzzy finder
      programs.fzf.enable = true;
      programs.fzf.enableZshIntegration = true;

      # ls replacement
      programs.eza.enable = true;
      programs.eza.enableZshIntegration = true;
      programs.eza.extraOptions = [
        "--git"
        "--group"
        "--header"
        "--time-style=relative"
        "--group-directories-first"
      ];

      # List files - terminal file manager
      programs.lf.enable = true;

      programs.tealdeer.enable = true;
      programs.tealdeer.enableAutoUpdates = true;

      # Fix whatever went wrong with the last command
      programs.pay-respects.enable = true;
      programs.pay-respects.enableZshIntegration = true;

      programs.git.enable = true;
      programs.git.settings = {
        user.name = "whitestrake";
        user.email = "git@whitestrake.net";
        core.fileMode = false;
        pull.rebase = true;
        push.autoSetupRemote = true;
      };

      programs.starship = {
        enable = true;
        enableZshIntegration = true;
        settings.username.format = "[$user]($style) at ";
        settings.username.show_always = true;
        settings.container.disabled = true;
      };

      programs.zsh = {
        enable = true;
        dotDir = config.home.homeDirectory;
        autosuggestion.enable = true;
        syntaxHighlighting.enable = true;
        profileExtra = ''
          if [[ -d /opt/docker ]]; then
            umask 0002
            cd /opt/docker
          fi
        '';
      };

      programs.helix = {
        enable = true;
        settings = {
          theme = "everblush";
          editor.true-color = true;
        };
        languages = {
          language-server = {
            nil.command = "${pkgs.nil}/bin/nil";
          };
          language = [
            {
              name = "nix";
              auto-format = true;
              formatter.command = "${pkgs.alejandra}/bin/alejandra";
              language-servers = ["nil"];
            }
          ];
        };
      };

      programs.home-manager.enable = true;
    };

    darwin.home-manager.users.whitestrake = {
      home.sessionVariables.EDITOR = "antigravity";
      home.shellAliases = {
        tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
        agy = "/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity";
      };
    };
  };

  # Export the user aspect under a namespace
  den.ful.whitestrake.user = config.den.aspects.whitestrake;
}
