{
  den,
  inputs,
  caches,
  mkLocalPackages,
  ...
}: let
  sharedNixSettings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@wheel" "@staff" "whitestrake"];
  };

  commonPackages = pkgs:
    with pkgs; [
      fish
      helix
      nh

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
in {
  den.aspects.common = {
    nixos = {pkgs, ...}: {
      nix.settings =
        sharedNixSettings
        // {
          download-buffer-size = 524288000;
          substituters = [caches.garnix.url caches.nix-community.url];
          trusted-public-keys = [caches.garnix.key caches.nix-community.key];
        };

      nixpkgs.overlays = [
        (final: prev: let
          unstablePkgs = import inputs.nixpkgs-unstable {
            system = prev.stdenv.hostPlatform.system;
            config.allowUnfree = true;
          };
        in {
          unstable = unstablePkgs;
          myPkgs = mkLocalPackages {
            pkgs = final;
            unstablePkgs = unstablePkgs;
          };
        })
      ];

      environment.systemPackages = commonPackages pkgs;
    };

    darwin = {pkgs, ...}: {
      nix.settings = sharedNixSettings;
      environment.systemPackages = commonPackages pkgs;

      environment.etc."nix/nix.custom.conf".text = let
        substituters = map (c: c.url) (builtins.attrValues caches);
        keys = map (c: c.key) (builtins.attrValues caches);
      in ''
        trusted-users = root @admin @staff whitestrake
        extra-substituters = ${builtins.concatStringsSep " " substituters}
        extra-trusted-public-keys = ${builtins.concatStringsSep " " keys}
      '';
    };
  };
}
