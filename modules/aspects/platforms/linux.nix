{den, ...}: {
  den.aspects.linux = {
    includes = [
      den.aspects.distributed-builds
    ];

    nixos = {
      config,
      pkgs,
      lib,
      ...
    }: {
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
              "timeo=50"
              "retrans=2"
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
          config.storage.cifsMounts;
      };
    };
  };
}
