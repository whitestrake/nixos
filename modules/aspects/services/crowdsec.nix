{
  den,
  inputs,
  ...
}: let
  bouncerModule = "services/security/crowdsec-firewall-bouncer.nix";
in {
  # CrowdSec on every server: the engine with a local API, the firewall
  # bouncer, sshd detection and the community blocklist. Hosts that face the
  # internet add den.aspects.crowdsec.edge for the HTTP scenarios.
  den.aspects.crowdsec = {
    nixos = {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.crowdsec;
      # Where the 26.05 module kept its state; pinned so hosts keep their
      # machine and Console identity.
      stateDir = "/var/lib/crowdsec/state";
      cscli = lib.getExe' cfg.package "cscli";
      docker = config.virtualisation.docker.enable;
    in {
      # FIXME: nixos-26.05 carries the old crowdsec module (written for 1.7);
      # nixos-unstable has a rewrite that fixes most of what this aspect used
      # to work around. Both modules come from unstable until the stable
      # channel includes the rewrite. The bouncer module moves with it because
      # it reads the rewrite's options. (26.05 has crowdsec.nix; the rewrite
      # is a directory.)
      disabledModules = ["services/security/crowdsec.nix" bouncerModule];
      imports = map (m: "${inputs.nixpkgs-unstable}/nixos/modules/${m}") ["services/security/crowdsec" bouncerModule];
      assertions = [
        {
          assertion = lib.versionOlder config.system.nixos.release "26.11";
          message = ''
            den.aspects.crowdsec imports the crowdsec modules from nixpkgs-unstable.
            If the stock module in this release is the rewrite (services/security/crowdsec/default.nix),
            remove the disabledModules/imports/assertion block.
          '';
        }
      ];

      services.crowdsec = {
        enable = true;
        # CrowdSec releases often and new hub content can need a newer engine,
        # so the packages track unstable for good, not just until the module
        # lands. When a nixpkgs-unstable bump moves CrowdSec a minor version,
        # check the unstable module's diff for matching changes.
        package = pkgs.unstable.crowdsec;

        hub = {
          collections = [
            "crowdsecurity/linux"
            "crowdsecurity/sshd"
          ];
          # RFC1918 and loopback; a parser, not a postoverflow.
          parsers = ["crowdsecurity/whitelists"];
        };

        settings = {
          acquisitions = [
            {
              source = "journalctl";
              journalctl_filter = ["_SYSTEMD_UNIT=sshd.service"];
              labels.type = "syslog";
            }
          ];

          parsers.s02Enrich = [
            {
              name = "homelab/tailnet-whitelist";
              description = "Never act on tailnet sources";
              whitelist = {
                reason = "tailnet";
                cidr = ["100.64.0.0/10" "fd7a:115c:a1e0::/48"];
              };
            }
          ];

          config = {
            config_paths.data_dir = stateDir;
            # The 26.05 module turned WAL on; keep the existing database as it is.
            db_config.use_wal = true;
            # Left unset, cscli takes hub content from the frozen branch for
            # its own version whenever it isn't the latest release, which on
            # unstable is most of the time. Track master instead (as the 26.05
            # module did). If master ever ships a scenario our engine can't
            # load, `crowdsec -t` fails the start on hosts that install it:
            # bump nixpkgs-unstable, or point this back at the engine's version
            # branch and force-reinstall the item on that host.
            cscli.hub_branch = "master";
            api.server = {
              # AMP's ADS holds 8080 on legion.
              listen_uri = "127.0.0.1:8095";
              console_path = "${stateDir}/console.yaml";
              # Without it the engine never registers with the Central API
              # and gets no community blocklist.
              online_client.credentials_path = "${stateDir}/online_api_credentials.yaml";
            };
          };

          # tmpfiles rewrites console.yaml on every activation, so the share
          # options live here. These are what `cscli console enroll` set.
          console.configuration = {
            share_manual_decisions = true;
            share_tainted = true;
            share_custom = true;
            share_context = true;
            console_management = false;
          };

          # Local scenarios ban. Set true to have them record alerts only
          # (the community blocklist is enforced either way).
          simulation.simulation = false;
        };
      };

      # tmpfiles rewrites simulation.yaml on activation, but nothing in the
      # unit changes with it, so crowdsec would carry on with the old mode
      # until its next restart.
      systemd.services.crowdsec.restartTriggers = [(builtins.toJSON cfg.settings.simulation)];

      # The 26.05 module linked its s02-enrich parsers under store-hash names,
      # and the copy left behind shadows the rewrite's 0-nixos-generated.yaml
      # (same parser name) until its store path is collected. Goes with the
      # FIXME block above.
      systemd.tmpfiles.settings."10-crowdsec-legacy"."/etc/crowdsec/parsers/s02-enrich/*-parsers-s02-enrich.yaml".r = {};

      services.crowdsec-firewall-bouncer = {
        enable = true;
        package = pkgs.unstable.crowdsec-firewall-bouncer;
        # Docker-published ports are DNATed through FORWARD and never reach
        # INPUT, so they need DOCKER-USER too.
        settings.iptables_chains = ["INPUT"] ++ lib.optional docker "DOCKER-USER";
      };

      # Docker creates DOCKER-USER; the bouncer skips a chain that's missing.
      # The bouncer also exits for good if the local API goes away, as it does
      # whenever crowdsec restarts, which would leave nothing enforcing.
      systemd.services.crowdsec-firewall-bouncer = {
        after = lib.optional docker "docker.service";
        wants = lib.optional docker "docker.service";
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "10s";
        };
      };

      # Console enrolment. The module's console.enrollKeyFile enrols from
      # crowdsec-setup on every start and fails setup (and the switch) if the
      # Console is unreachable, so enrol from our own timer instead.
      # `cscli capi status` only reports enrolment once the engine has been
      # accepted in the Console, so a marker in the state dir records that we
      # enrolled. A timer drives it so a Console outage never fails a switch.
      sops.secrets.crowdsecConsoleEnrollKey = {};
      systemd.services.crowdsec-console-enroll = {
        description = "Enrol the CrowdSec engine in the CrowdSec Console";
        after = ["crowdsec.service" "network-online.target"];
        wants = ["network-online.target"];
        unitConfig.ConditionPathExists = "!${stateDir}/console-enrolled";
        serviceConfig.Type = "oneshot";
        script = ''
          cscli() { ${pkgs.util-linux}/bin/runuser -u ${cfg.user} -- ${cscli} "$@"; }
          if cscli capi status 2>&1 | grep -q 'enrolled in the console'; then
            touch ${stateDir}/console-enrolled
            exit 0
          fi
          if cscli console enroll --name ${lib.escapeShellArg config.networking.hostName} \
            "$(cat ${config.sops.secrets.crowdsecConsoleEnrollKey.path})"; then
            touch ${stateDir}/console-enrolled
            systemctl --no-block try-restart crowdsec.service
          else
            echo "Console enrolment failed; the timer tries again in an hour." >&2
          fi
        '';
      };
      # A successful enrol restarts crowdsec. OnActiveSec (not OnBootSec, which
      # has long passed on a running host) keeps that restart out of the
      # switch that adds the timer, where it would knock over the bouncer
      # while it starts and fail the deploy.
      systemd.timers.crowdsec-console-enroll = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnActiveSec = "2min";
          OnUnitInactiveSec = "1h";
        };
      };
    };
  };

  # Extra scenarios for hosts that serve HTTP to the internet. Each host adds
  # its own proxy's collection and access-log acquisition.
  den.aspects.crowdsec.edge = {
    includes = [den.aspects.crowdsec];
    nixos = {
      services.crowdsec.hub = {
        collections = [
          "crowdsecurity/http-cve"
          "crowdsecurity/base-http-scenarios"
        ];
        # Never ban CDN edges (Cloudflare-proxied names reach orthus Caddy).
        postoverflows = ["crowdsecurity/cdn-whitelist"];
      };
    };
  };
}
