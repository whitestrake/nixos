{den, ...}: {
  # Server aspect wires in monitoring, deployment, health, and Tailscale networking
  den.aspects.server = {
    includes = [
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
      options.den.deploy.health = {
        enable = lib.mkEnableOption "Cachix Deploy post-activation health checks";

        allowUnprotected = lib.mkOption {
          type = lib.types.bool;
          default = false;
          example = true;
          description = ''
            Allow a Cachix-managed host to pass deployment without health checks
            when `den.deploy.health.enable` is false. When this is false, the
            generated rollback script fails closed for Cachix-managed hosts with
            disabled or missing health checks.
          '';
        };

        requiredSystemdUnits = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = [
            "sshd.service"
            "tailscaled.service"
          ];
          description = ''
            Systemd units that must be active after deployment. These checks are
            emitted into the generated Cachix rollback script with a small retry
            budget to avoid false failures while services finish starting.
          '';
        };

        requiredCommands = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          example = lib.literalExpression ''
            {
              dns = "''${pkgs.dig}/bin/dig +short whitestrake.net";
              tailscale = "''${config.services.tailscale.package}/bin/tailscale status --peers=false";
            }
          '';
          description = ''
            Named shell commands that must exit successfully after deployment.
            Commands are executed on the target host by the generated rollback
            script via `bash -c`.
          '';
        };

        requiredHttpEndpoints = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              url = lib.mkOption {
                type = lib.types.str;
                example = "http://127.0.0.1:8123/";
                description = "HTTP or HTTPS URL to check after deployment.";
              };

              expectStatus = lib.mkOption {
                type = lib.types.int;
                default = 200;
                example = 204;
                description = "Expected HTTP status code.";
              };
            };
          });
          default = {};
          example = {
            home-assistant = {
              url = "http://127.0.0.1:8123/";
              expectStatus = 200;
            };
          };
          description = ''
            Named HTTP endpoints that must return the expected status after
            deployment. These checks are useful for services where systemd
            readiness is not enough to prove the service is usable.
          '';
        };

        extraCheckScript = lib.mkOption {
          type = lib.types.lines;
          default = "";
          example = ''
            test -e /run/some-service/ready
          '';
          description = ''
            Extra shell commands appended to this host's generated health checks.
            Use this for host-specific checks that do not fit the structured
            systemd, command, or HTTP check options.
          '';
        };
      };

      config = {
        den.deploy.health = {
          enable = lib.mkDefault true;
          allowUnprotected = lib.mkDefault false;
          requiredSystemdUnits = [
            "sshd.service"
            "tailscaled.service"
            "cachix-agent.service"
          ];
          requiredCommands = {
            dns = "${pkgs.dig}/bin/dig +short whitestrake.net";
            tailscale = "${config.services.tailscale.package}/bin/tailscale status --peers=false";
          };
        };

        sops.secrets.tailscaleOauthKey = {};
        services.tailscale = {
          authKeyFile = config.sops.secrets.tailscaleOauthKey.path;
          useRoutingFeatures = "both";
          authKeyParameters.ephemeral = false;
          extraUpFlags = ["--advertise-tags=tag:server"];
        };

        systemd.services.tailscaled.serviceConfig.ExecStartPost = ''
          ${pkgs.coreutils}/bin/timeout 60s ${pkgs.bash}/bin/bash -c 'until ${config.services.tailscale.package}/bin/tailscale status --peers=false; do sleep 1; done'
        '';
      };
    };
  };

  # Homelab servers have a subdomain for internal addressing
  den.aspects.server.lab = {
    includes = [den.aspects.server];
    nixos.networking.domain = "lab.whitestrake.net";
  };
}
