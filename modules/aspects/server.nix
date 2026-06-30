{den, ...}: {
  # Server aspect wires in monitoring, deployment, health, and Tailscale networking
  den.aspects.server = {
    includes = [
      den.aspects.distributed-builds
      den.aspects.monitoring
      den.aspects.cachix-agent
    ];

    # Don't need man pages on headless servers
    os.documentation.enable = false;

    nixos = {
      config,
      pkgs,
      lib,
      ...
    }: {
      config = let
        tailscaleReadyCommand = "${config.services.tailscale.package}/bin/tailscale status --peers=false";
      in {
        nix.settings.auto-optimise-store = true;

        nixpkgs.overlays = [
          (final: prev: {
            dhcpcd = final.unstable.dhcpcd;
          })
        ];

        # Allow sudo via SSH key.
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

        services.sshguard.enable = true;
        systemd.services.sshguard.serviceConfig.TimeoutStopSec = "10s";
        services.openssh = {
          enable = true;
          settings = {
            PermitRootLogin = "no";
            PasswordAuthentication = false;
          };
        };

        services.tailscale = {
          enable = lib.mkDefault true;
          package = pkgs.unstable.tailscale;
          openFirewall = true;
          authKeyFile = config.sops.secrets.tailscaleOauthKey.path;
          useRoutingFeatures = "both";
          authKeyParameters.ephemeral = false;
          extraUpFlags = ["--advertise-tags=tag:server"];
        };

        users.users.www-data = {
          isSystemUser = true;
          group = "www-data";
          uid = 33;
        };
        users.groups.www-data.gid = 33;

        den.deploy.health = {
          requiredSystemdUnits = [
            "sshd.service"
            "tailscaled.service"
          ];
          requiredCommands = {
            dns = "${pkgs.dig}/bin/dig +short whitestrake.net";
            tailscale = tailscaleReadyCommand;
          };
        };

        sops.secrets.tailscaleOauthKey = {};

        systemd.services.tailscaled.serviceConfig.ExecStartPost = ''
          ${pkgs.coreutils}/bin/timeout 60s ${pkgs.bash}/bin/bash -c 'until ${tailscaleReadyCommand}; do sleep 1; done'
        '';
      };
    };
  };

  # Homelab servers have a subdomain for internal addressing
  den.aspects.server.lab = {
    includes = [den.aspects.server];
    nixos = {
      config,
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
        networking.domain = "lab.whitestrake.net";

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
              "echo_interval=10"
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
