{
  den,
  lib,
  ...
}: {
  config = {
    den.schema.user.classes = lib.mkDefault ["homeManager"];

    # Base overrides applied globally to classes
    den.default = {
      includes = [den.provides.hostname];

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

      darwin = {lib, ...}: {
        system.stateVersion = lib.mkDefault 4;
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

  options = {
    network.tailnetSuffix = lib.mkOption {
      type = lib.types.str;
      default = "fell-monitor.ts.net";
      description = "Tailnet DNS suffix appended to host names for tailnet-internal addressing";
    };
  };
}
