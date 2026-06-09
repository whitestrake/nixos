{
  caches,
  den,
  inputs,
  lib,
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
  flake-file.inputs.sops-nix = {
    url = "github:Mic92/sops-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.schema.user.classes = lib.mkDefault ["homeManager"];
  den.schema.host.includes = [den.aspects.common];

  den.aspects.common = {
    nixos = {
      pkgs,
      lib,
      ...
    }: {
      nix.settings =
        sharedNixSettings
        // {
          download-buffer-size = 524288000;
          substituters = lib.mkBefore [caches.garnix.url caches.nix-community.url];
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

  # Base overrides applied globally to classes
  den.default = {
    includes = [
      den.provides.hostname
      den.policies.flake-root
    ];

    nixos = {
      pkgs,
      lib,
      ...
    }: {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;

      system.stateVersion = lib.mkDefault "24.05";
      nixpkgs.config.allowUnfree = true;
      time.timeZone = lib.mkDefault "Australia/Brisbane";
      networking.domain = lib.mkDefault "whitestrake.net";
      documentation.nixos.enable = false;
      imports = [inputs.sops-nix.nixosModules.sops];
      sops = {
        # Default secret file
        defaultSopsFile = ../secrets/secrets.yaml;
        # Auto import SSH host key to age
        age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
        # Default key location
        age.keyFile = "/var/lib/sops-nix/key.txt";
        # Create key if it doesn't exist
        age.generateKey = true;
      };
    };

    darwin = {
      pkgs,
      lib,
      ...
    }: {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;

      system.stateVersion = lib.mkDefault 4;
      nixpkgs.config.allowUnfree = true;
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
}
