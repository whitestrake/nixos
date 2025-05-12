{pkgs, ...}: {
  home.stateVersion = "23.11";
  home.sessionVariables = {
    COMPOSE_IGNORE_ORPHANS = "True";
    EDITOR = "helix";
    BAT_PAGING = "never";
    BAT_THEME = "TwoDark";
  };
  home.shellAliases = {
    l = "eza -lgh --group-directories-first --git-ignore --git --time-style=relative";
    la = "eza -lgaah --group-directories-first --git-ignore --git --time-style=long-iso";
    lg = "eza -lgaah --group-directories-first --git --time-style=long-iso";
    dps = "docker ps -as --format 'table {{.Names}}\t{{.Status}}\t{{.Size}}'";
    dc = "docker compose";
    dcl = "dc logs -f --tail 20";
    df = "df -h -xtmpfs -xoverlay";
  };

  home.packages = with pkgs; [
    ffmpeg
    yt-dlp
    bat
  ];

  programs.autojump.enable = true;
  programs.autojump.enableFishIntegration = true;
  programs.fzf.enable = true;
  programs.fzf.enableFishIntegration = true;

  programs.eza.enable = true;
  programs.eza.enableFishIntegration = true;
  programs.lf.enable = true;

  programs.tealdeer.enable = true;
  # programs.tealdeer.enableAutoUpdates = true; # newer than home-manager 24.11

  programs.thefuck.enable = true;
  programs.thefuck.enableFishIntegration = true;

  programs.git = {
    enable = true;
    userName = "whitestrake";
    userEmail = "git@whitestrake.net";
    extraConfig.core.fileMode = false;
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
    interactiveShellInit = ''
      set fish_greeting
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
