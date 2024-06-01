{
  pkgs,
  inputs,
  ...
}: {
  imports = [inputs.home-manager.darwinModules.home-manager];

  # Enable touch ID for sudo
  security.pam.enableSudoTouchIdAuth = true;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;

  fonts.fontDir.enable = true;
  fonts.fonts = with pkgs; [
    (nerdfonts.override {
      fonts = [
        "FiraCode"
        "DroidSansMono"
        "Meslo"
        "Inconsolata"
      ];
    })
  ];

  # Unstable nixpkgs access
  nixpkgs.overlays = [
    (final: _prev: {
      unstable = import inputs.nixpkgs-unstable {
        system = final.system;
        config.allowUnfree = true;
      };
    })
  ];

  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    btop
    tree
    ranger
    rclone
    rar
    powershell
    iperf
    watch
    go
    caddy
    xcaddy
    duplicacy
    wget
    curl
    dig
    jq
    fx
    age
    sops
    deploy-rs
    nil
    alejandra

    # https://github.com/NixOS/nixpkgs/issues/287861
    unstable.ncdu
  ];

  # Add shells to /etc/shells so that they can be selected for by users
  environment.shells = with pkgs; [fish];

  # Use Homebrew for GUI apps; nix-darwin and home-manager suck at it
  homebrew = {
    enable = true;
    onActivation.autoUpdate = true;
    onActivation.upgrade = true;
    brews = [
      "samba"
      "bitwarden-cli"
      "java"
      "curl"
    ];
    casks = [
      "visual-studio-code"
      "notunes"
      "iina"
      "raycast"
      "warp"
      "obsidian"
    ];
  };

  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;
  nix.package = pkgs.nix;
  nix.settings = {
    "extra-experimental-features" = ["nix-command" "flakes"];
  };

  # User configuration
  programs.fish.enable = true;
  programs.zsh.enable = true;
  users.users.whitestrake.shell = pkgs.fish;
  users.users.whitestrake.home = "/Users/whitestrake";
  home-manager.users.whitestrake = {lib, ...}: {
    imports = [../users/whitestrake/home.nix];
    home.sessionVariables.EDITOR = lib.mkForce "code"; # VS Code
    home.sessionVariables.CLICOLOR = lib.mkForce "1"; # Enable colours in terminal outputs
    home.shellAliases.tailscale = lib.mkForce "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
    programs.fish.interactiveShellInit = lib.mkForce ''
      set fish_greeting
      thefuck --alias | source
      fish_add_path $GOPATH/bin/
    '';
  };

  # home-manager.users.whitestrake = {pkgs, ...}: {
  #   home.stateVersion = "22.11";
  #   home.sessionVariables = {
  #     EDITOR = "code"; # VS Code
  #     CLICOLOR = "1"; # Enable colours in terminal outputs
  #   };
  #   home.shellAliases = {
  #     l = "ls -lh";
  #     la = "ls -lah";
  #     df = "df -h -xtmpfs -xoverlay";
  #     tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
  #   };
  #   home.packages = with pkgs; [
  #     autojump
  #     ffmpeg
  #     fzf
  #     thefuck
  #     vimpager
  #     yt-dlp
  #   ];

  #   programs.autojump.enable = true;
  #   programs.autojump.enableFishIntegration = true;
  #   programs.fzf.enable = true;
  #   programs.fzf.enableFishIntegration = true;

  #   programs.git = {
  #     enable = true;
  #     userName = "whitestrake";
  #     userEmail = "git@whitestrake.net";
  #   };

  #   programs.fish = {
  #     enable = true;
  #     interactiveShellInit = ''
  #       set fish_greeting
  #       thefuck --alias | source
  #       fish_add_path $GOPATH/bin/
  #     '';
  #   };

  #   programs.starship = {
  #     enable = true;
  #     enableFishIntegration = true;
  #     settings.username.format = ''[$user]($style) at '';
  #     settings.username.show_always = true;
  #     settings.container.disabled = true;
  #   };

  #   programs.vim = {
  #     enable = true;
  #     plugins = with pkgs.vimPlugins; [vim-hexokinase vim-airline onedark-vim];
  #     settings.ignorecase = true;
  #     extraConfig = ''
  #       let g:Hexokinase_highlighters = ['foreground']
  #       syntax enable
  #       silent! colorscheme onedark
  #       set backspace=indent,eol,start  " Remove limits on backspace
  #       set tabstop=2                   " num visual spaces per TAB
  #       set softtabstop=2               " num spaces per TAB when editing
  #       set shiftwidth=2                " num spaces for (auto) indent
  #       set laststatus=2                " always show laststatus line (for airline)
  #       set expandtab                   " convert tabs to spaces
  #       set number                      " show line numbers
  #       set cursorline                  " highlight current line
  #       set wildmenu                    " show autocomplete menu
  #       set lazyredraw                  " redraw only when needed
  #       set showmatch                   " highlight matching parenthesis
  #       set incsearch                   " incremental search as you type
  #       set ignorecase                  " ignore case in searches
  #       set smartcase                   " only ignore case in searches when lower cased
  #       set ttyfast                     " indicate fast terminal connection (quicker rendering)
  #       set textwidth=80                " 80 character text width
  #       set formatoptions-=t            " disable auto newline insertion at text width
  #       set wrap                        " soft wrap text
  #       set visualbell                  " blink cursor instead of beeping
  #       set confirm                     " use confirmation box on unsaved files
  #       set nomodeline                  " security
  #       set backupcopy=yes              " edit files in place (needed for Docker)
  #     '';
  #   };
  # };
}
