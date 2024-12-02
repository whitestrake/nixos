{pkgs, ...}: {
  home.stateVersion = "23.11";
  home.sessionVariables = {
    COMPOSE_IGNORE_ORPHANS = "True";
    EDITOR = "vim";
    BAT_PAGING = "never";
    BAT_THEME = "TwoDark";
    FLAKE = "github:whitestrake/nixos";
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
    autojump
    ffmpeg
    fzf
    thefuck
    vimpager
    yt-dlp
    eza
    bat
    helix
    tealdeer
  ];

  programs.autojump.enable = true;
  programs.autojump.enableFishIntegration = true;
  programs.fzf.enable = true;
  programs.fzf.enableFishIntegration = true;

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
      thefuck --alias | source
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
    languages.language = [
      {
        name = "nix";
        auto-format = true;
        formatter.command = "${pkgs.alejandra}/bin/alejandra";
      }
    ];
  };

  programs.vim = {
    enable = true;
    plugins = with pkgs.vimPlugins; [vim-hexokinase vim-airline onedark-vim];
    settings.ignorecase = true;
    extraConfig = ''
      let g:Hexokinase_highlighters = ['foreground']
      syntax enable
      silent! colorscheme onedark
      set backspace=indent,eol,start  " Remove limits on backspace
      set tabstop=2                   " num visual spaces per TAB
      set softtabstop=2               " num spaces per TAB when editing
      set shiftwidth=2                " num spaces for (auto) indent
      set laststatus=2                " always show laststatus line (for airline)
      set expandtab                   " convert tabs to spaces
      set number                      " show line numbers
      set cursorline                  " highlight current line
      set wildmenu                    " show autocomplete menu
      set lazyredraw                  " redraw only when needed
      set showmatch                   " highlight matching parenthesis
      set incsearch                   " incremental search as you type
      set ignorecase                  " ignore case in searches
      set smartcase                   " only ignore case in searches when lower cased
      set ttyfast                     " indicate fast terminal connection (quicker rendering)
      set textwidth=80                " 80 character text width
      set formatoptions-=t            " disable auto newline insertion at text width
      set wrap                        " soft wrap text
      set visualbell                  " blink cursor instead of beeping
      set confirm                     " use confirmation box on unsaved files
      set nomodeline                  " security
      set backupcopy=yes              " edit files in place (needed for Docker)
    '';
  };

  programs.home-manager.enable = true;
}
