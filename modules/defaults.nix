{
  den,
  lib,
  ...
}: {
  config = {
    den.schema.user.classes = lib.mkDefault ["homeManager"];
    den.schema.host.options.tailnetSuffix = lib.mkOption {
      type = lib.types.str;
      default = "fell-monitor.ts.net";
      description = "Tailnet DNS suffix appended to this Den host name for tailnet-internal addressing";
    };

    # Base overrides applied globally to classes
    den.default = {
      includes = [den.provides.hostname];

      wsl-host = {
        config,
        pkgs,
        ...
      }: {
        # Keep the WSL SSH agent bridge available outside interactive sessions.
        users.users.${config.wsl.defaultUser}.linger = true;

        environment.systemPackages = with pkgs; [
          powershell
        ];

        # Explicit ssh-agent enablement in WSL
        wsl.ssh-agent.enable = true;

        # Fix for running Windows binaries (Exec format error)
        environment.etc."binfmt.d/WSLInterop.conf".text = ":WSLInterop:M::MZ::/init:PF";

        # Use systemd-resolved for native, robust mDNS resolution
        services.resolved = {
          enable = true;
          settings.Resolve = {
            LLMNR = "false";
            MulticastDNS = "resolve";
          };
        };
      };

      os = {pkgs, ...}: {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
        nixpkgs.config.allowUnfree = true;
        environment.systemPackages = with pkgs; [
          fish
          helix
          nh
          git

          # File system tools
          dua
          tree
          rclone

          # Search tools
          fd
          ripgrep

          # Data inspection
          jq
          fx

          # Network clients
          wget
          curl
          xh

          # Troubleshooting
          btop
          mtr
          tcpdump
          dig
          whois
          rdap
          iperf
        ];
      };

      nixos = {lib, ...}: {
        system.stateVersion = lib.mkDefault "24.05";
        time.timeZone = lib.mkDefault "Australia/Brisbane";
        networking.domain = lib.mkDefault "whitestrake.net";

        # Allow running non-Nix dynamic binaries.
        programs.nix-ld.enable = true;

        programs.nh = {
          enable = true;
          flake = "github:whitestrake/nixos";
          clean = {
            enable = true;
            dates = "daily";
            extraArgs = "--keep-since 7d --keep 5";
          };
        };
      };

      darwin = {
        config,
        lib,
        pkgs,
        ...
      }: {
        system.stateVersion = lib.mkDefault 4;

        # macOS System Settings
        security.pam.services.sudo_local.touchIdAuth = true;
        system.defaults.LaunchServices.LSQuarantine = false;
        programs.zsh.enable = true;

        fonts.packages = with pkgs; [
          nerd-fonts.meslo-lg
          nerd-fonts.fira-code
          nerd-fonts.inconsolata
          nerd-fonts.droid-sans-mono
        ];

        environment.systemPackages = with pkgs; [
          watch
          go
          caddy
          xcaddy
          duplicacy
          zulu
          samba
          cacert
        ];

        environment.shells = with pkgs; [fish];

        # Homebrew
        homebrew = {
          enable = true;
          onActivation = {
            cleanup = "zap";
            extraFlags = ["--force-cleanup"];
          };
          brews = ["bitwarden-cli"];
          casks = [
            "music-decoy"
            "finetune"
            "visual-studio-code"
            "iina"
            "raycast"
            "warp"
            "obsidian"
            "soduto"
            "kando"
            "jordanbaird-ice@beta"
          ];
        };

        environment.variables = {
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          CURL_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        };
      };

      homeManager = {
        pkgs,
        lib,
        ...
      }: {
        home.stateVersion = lib.mkDefault "25.11";
        manual.html.enable = false;
        manual.manpages.enable = false;
        manual.json.enable = false;
      };
    };
  };
}
