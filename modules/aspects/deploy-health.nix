{...}: {
  den.aspects.deploy-health = {
    nixos = {
      config,
      pkgs,
      lib,
      ...
    }: {
      options.den.deploy.health = {
        enable = lib.mkEnableOption "deployment health checks";

        allowUnprotected = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Allow the Cachix-managed host to deploy without running health checks";
        };

        requiredSystemdUnits = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "List of systemd services that must be active for the deployment to succeed";
        };

        requiredCommands = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "Attribute set of commands that must return exit code 0";
        };

        requiredHttpEndpoints = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              url = lib.mkOption {
                type = lib.types.str;
                description = "The HTTP/HTTPS URL to check";
              };
              expectStatus = lib.mkOption {
                type = lib.types.int;
                default = 200;
                description = "Expected HTTP status code";
              };
            };
          });
          default = {};
          description = "HTTP endpoints that must return the expected status code";
        };

        extraCheckScript = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Extra shell script commands to execute during the health check";
        };
      };
    };
  };
}
