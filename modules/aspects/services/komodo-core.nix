{...}: let
  # When false, both services are installed but not started at boot, not
  # health-checked on deploy, and the host does not opt into the Komodo Fleet
  # pipeline. Used to stage the services before cutover.
  active = true;

  stateDir = "/var/lib/komodo-core";
  # Nightly `km database backup` dumps stay under /opt/docker, which the host
  # rsync pulls already cover.
  backupsDir = "/opt/docker/komodo/backups";
in {
  den.aspects.komodo-core = {
    nixos = {
      config,
      lib,
      pkgs,
      ...
    }: let
      komodo = pkgs.unstable.komodo;
      placeholder = config.sops.placeholder;
    in {
      # MongoDB's own authorisation is on through extraConfig rather than
      # enableAuth: the module's auth bootstrap would add a second root user
      # to the copied data. Users live in the data directory itself.
      services.mongodb = {
        enable = true;
        package = pkgs.unstable.mongodb-ce;
        bind_ip = "127.0.0.1";
        dbpath = "/var/lib/mongodb";
        quiet = true;
        extraConfig = ''
          security.authorization: enabled
          storage.wiredTiger.engineConfig.cacheSizeGB: 0.25
        '';
      };
      systemd.services.mongodb = {
        wantedBy = lib.mkIf (!active) (lib.mkForce []);
        # MongoDB 8.2 crash-loops on Linux >= 6.19 on CPUs with shadow-stack
        # support (moghtech/komodo#1320). Harmless where it does not apply.
        environment.GLIBC_TUNABLES = "glibc.cpu.hwcaps=-SHSTK";
        serviceConfig.LimitNOFILE = 64000;
      };

      # For administration and the runbook's featureCompatibilityVersion raise.
      environment.systemPackages = [pkgs.mongosh];

      users.users.komodo-core = {
        isSystemUser = true;
        group = "komodo-core";
        home = stateDir;
      };
      users.groups.komodo-core = {};

      sops.secrets = {
        komodoCoreDbPassword = {};
        komodoCoreJwtSecret = {};
        komodoCoreWebhookSecret = {};
        komodoCoreOidcClientSecret = {};
        komodoMongoMonitorPassword = {};
      };
      # Read by systemd as root before dropping privileges, and inherited by the
      # `km` processes Core spawns for database backups.
      sops.templates."komodo-core.env".content = ''
        KOMODO_DATABASE_PASSWORD=${placeholder.komodoCoreDbPassword}
        KOMODO_JWT_SECRET=${placeholder.komodoCoreJwtSecret}
        KOMODO_WEBHOOK_SECRET=${placeholder.komodoCoreWebhookSecret}
        KOMODO_OIDC_CLIENT_SECRET=${placeholder.komodoCoreOidcClientSecret}
      '';
      sops.templates."alloy-komodo.env".content = ''
        KOMODO_MONGODB_URI=mongodb://monitor:${placeholder.komodoMongoMonitorPassword}@127.0.0.1:27017/admin
      '';

      systemd.services.komodo-core = {
        description = "Komodo Core";
        wantedBy = lib.optionals active ["multi-user.target"];
        after = ["network-online.target" "mongodb.service"];
        wants = ["network-online.target"];
        requires = ["mongodb.service"];
        # git for repos and syncs; km for scheduled database backups. Komodo
        # checks for git with `which git` before every clone or pull.
        path = [komodo pkgs.git pkgs.which];

        environment = {
          HOME = stateDir;
          KOMODO_HOST = "https://komodo.whitestrake.net";
          KOMODO_TITLE = "Komodo";
          # Pangolin reaches Core on the Docker bridge address (172.17.0.1)
          # while health checks use 127.0.0.1. Do not narrow to loopback.
          KOMODO_BIND_IP = "[::]";
          KOMODO_PORT = "9120";
          KOMODO_TIMEZONE = "Australia/Brisbane";
          KOMODO_UI_PATH = "${pkgs.myPkgs.komodo-ui}";
          KOMODO_PRIVATE_KEY = "file:${stateDir}/keys/core.key";
          KOMODO_REPO_DIRECTORY = "${stateDir}/repo-cache";
          KOMODO_SYNC_DIRECTORY = "${stateDir}/syncs";
          KOMODO_ACTION_DIRECTORY = "${stateDir}/action-cache";
          KOMODO_CONFIG_PATHS = stateDir;
          KOMODO_CLI_CONFIG_PATHS = stateDir;
          KOMODO_CLI_BACKUPS_FOLDER = "${stateDir}/backups";

          KOMODO_DATABASE_ADDRESS = "127.0.0.1:27017";
          KOMODO_DATABASE_USERNAME = "komodo";

          KOMODO_MONITORING_INTERVAL = "15-sec";
          KOMODO_RESOURCE_POLL_INTERVAL = "5-min";
          KOMODO_JWT_TTL = "1-day";
          KOMODO_DISABLE_CONFIRM_DIALOG = "false";
          KOMODO_DISABLE_USER_REGISTRATION = "false";
          KOMODO_ENABLE_NEW_USERS = "false";
          KOMODO_DISABLE_NON_ADMIN_CREATE = "false";
          KOMODO_TRANSPARENT_MODE = "false";

          KOMODO_OIDC_ENABLED = "true";
          KOMODO_OIDC_PROVIDER = "https://authentik.whitestrake.net/application/o/komodo/";
          KOMODO_OIDC_REDIRECT_HOST = "https://authentik.whitestrake.net/";
          KOMODO_OIDC_CLIENT_ID = "st7HCWsgMQsRvJceuhAOdvCnNoQo7ErGGGgIv54K";
          KOMODO_OIDC_USE_FULL_EMAIL = "true";
        };

        serviceConfig = {
          ExecStart = lib.getExe' komodo "core";
          EnvironmentFile = config.sops.templates."komodo-core.env".path;
          User = "komodo-core";
          Group = "komodo-core";
          StateDirectory = "komodo-core";
          StateDirectoryMode = "0750";
          WorkingDirectory = stateDir;
          BindPaths = ["${backupsDir}:${stateDir}/backups"];
          Restart = "on-failure";
          RestartSec = 5;

          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
        };
      };

      # Containers on any user-defined Docker bridge (Newt on `proxy`) reach
      # Core through host.docker.internal; nothing else does.
      networking.firewall.interfaces."br-+".allowedTCPPorts = [9120];

      # Alloy's MongoDB exporter connects as the read-only monitoring user.
      systemd.services.alloy.serviceConfig.EnvironmentFile = [
        config.sops.templates."alloy-komodo.env".path
      ];
      den.alloy.fleetAttributes."telemetry.komodo" = active;

      den.deploy.health = lib.mkIf active {
        requiredSystemdUnits = ["mongodb.service" "komodo-core.service"];
        requiredCommands.komodo-core = ''
          ${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 5 http://127.0.0.1:9120/ >/dev/null
        '';
      };
    };
  };
}
