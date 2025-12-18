{pkgs, ...}: {
  home.stateVersion = "23.11";
  home.sessionVariables = {
    COMPOSE_IGNORE_ORPHANS = "True";
    EDITOR = "helix";
    BAT_PAGING = "never";
    BAT_THEME = "TwoDark";
  };
  home.shellAliases = {
    l = "eza --long --git-ignore";
    la = "eza --long --all --all --time-style=long-iso";
    df = "df -h -xtmpfs -xoverlay";
  };

  home.packages = with pkgs; [
    ffmpeg
    yt-dlp
    bat
  ];

  # Autojump
  programs.zoxide.enable = true;
  programs.zoxide.enableFishIntegration = true;
  programs.zoxide.options = ["--cmd j"];

  # Command-line fuzzy finder
  programs.fzf.enable = true;
  programs.fzf.enableFishIntegration = true;

  # ls replacement
  programs.eza.enable = true;
  programs.eza.enableFishIntegration = true;
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

  programs.git.enable = true;
  programs.git.settings = {
    user.name = "whitestrake";
    user.email = "git@whitestrake.net";
    core.fileMode = false;
  };

  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    settings.username.format = "[$user]($style) at ";
    settings.username.show_always = true;
    settings.container.disabled = true;
  };

  programs.fish = {
    enable = true;
    # binds.ctrl-c.command = "cancel-commandline"; # not available just yet
    interactiveShellInit = ''
      set fish_greeting
      for mode in (bind --list-modes)
        bind -M $mode ctrl-c cancel-commandline
      end
    '';
    loginShellInit = ''
      if test -d /opt/docker
        umask 0002
        cd /opt/docker
      end
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
}
