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

  den.aspects.linux = {
    includes = [
      den.aspects.common
      den.aspects.distributed-builds
    ];

    nixos = {
      config,
      pkgs,
      lib,
      ...
    }: let
      cifsMounts = config.storage.cifsMounts;
    in {
      options.storage.cifsMounts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            device = lib.mkOption {
              type = lib.types.str;
              description = "The CIFS share device path (e.g. //server/share)";
            };
            uid = lib.mkOption {
              type = lib.types.int;
              description = "User ID to own the mounted files";
            };
            gid = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Group ID to own the mounted files (defaults to uid)";
            };
            credentials = lib.mkOption {
              type = lib.types.str;
              description = "Path to the credentials file";
            };
          };
        });
        default = {};
        example = {
          "/mnt/media" = {
            device = "//tempus.lab.whitestrake.net/Media";
            uid = 1001;
            credentials = "/run/secrets/smbCredentials/host@tempus";
          };
        };
        description = ''
          Declarative CIFS mounts keyed by mount point path. Each entry is
          rendered into a NixOS fileSystems entry using fsType = "cifs".
        '';
      };

      config = {
        nix.settings.auto-optimise-store = true;
        programs.nh = {
          enable = true;
          flake = "github:whitestrake/nixos";
          clean = {
            enable = true;
            dates = "daily";
            extraArgs = "--keep-since 7d --keep 5";
          };
        };

        nixpkgs.overlays = [
          (final: prev: {
            dhcpcd = final.unstable.dhcpcd;
          })
        ];

        # Allow non-nix executables
        programs.nix-ld.enable = true;

        # Allow sudo via SSH key
        security.pam.sshAgentAuth.enable = true;
        security.pam.services.sudo.sshAgentAuth = true;

        environment.systemPackages = with pkgs; [
          service-wrapper
          iftop
          iotop
          ethtool
          lsof
          pciutils
          usbutils
        ];

        # Set up basic SSH protection
        services.sshguard.enable = true;
        systemd.services.sshguard.serviceConfig.TimeoutStopSec = "10s";
        services.openssh = {
          enable = true;
          settings = {
            PermitRootLogin = "no";
            PasswordAuthentication = false;
          };
        };

        # Tailscale networking
        services.tailscale = {
          enable = lib.mkDefault true;
          package = pkgs.unstable.tailscale;
          useRoutingFeatures = lib.mkDefault "client";
          openFirewall = true;
        };

        # www-data user
        users.users.www-data = {
          isSystemUser = true;
          group = "www-data";
          uid = 33;
        };
        users.groups.www-data.gid = 33;

        fileSystems =
          lib.mapAttrs (path: mount: {
            inherit (mount) device;
            fsType = "cifs";
            noCheck = true;
            options = [
              "soft"
              "nofail"
              "_netdev"
              "x-systemd.automount"
              "x-systemd.idle-timeout=60"
              "x-systemd.mount-timeout=5"
              "x-systemd.device-timeout=5"
              "file_mode=0660"
              "dir_mode=0770"
              "credentials=${mount.credentials}"
              "uid=${toString mount.uid}"
              "gid=${toString (
                if mount.gid != null
                then mount.gid
                else mount.uid
              )}"
            ];
          })
          cifsMounts;
      };
    };
  };
}
