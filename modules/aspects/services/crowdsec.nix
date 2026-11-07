{den, ...}: {
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
      stateDir = "/var/lib/crowdsec/state";
      cscli = lib.getExe' cfg.package "cscli";
      docker = config.virtualisation.docker.enable;
    in {
      services.crowdsec = {
        enable = true;

        hub = {
          collections = [
            "crowdsecurity/linux"
            "crowdsecurity/sshd"
          ];
          # RFC1918 and loopback; a parser, not a postoverflow.
          parsers = ["crowdsecurity/whitelists"];
        };

        localConfig = {
          acquisitions = [
            {
              source = "journalctl";
              journalctl_filter = ["_SYSTEMD_UNIT=sshd.service"];
              labels.type = "syslog";
            }
          ];

          # Every s02-enrich entry renders to the same file name, so keep a
          # single entry here.
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
        };

        settings = {
          general.api.server = {
            enable = true;
            # AMP's ADS holds 8080 on legion.
            listen_uri = "127.0.0.1:8095";
            # Writable, so `cscli console enroll` can save its options.
            console_path = "${stateDir}/console.yaml";
          };
          # Both default to null; without the CAPI path the engine never
          # registers, and gets no community blocklist.
          lapi.credentialsFile = "${stateDir}/local_api_credentials.yaml";
          capi.credentialsFile = "${stateDir}/online_api_credentials.yaml";
          # Local scenarios record alerts without banning. Community blocklist
          # decisions are not simulated and are enforced.
          simulation.simulation = true;
        };
      };

      # The bouncer's registration unit runs the bare cscli, which reads
      # /etc/crowdsec/config.yaml; the module only passes its config with -c.
      # Remove once nixpkgs points that unit at the wrapped cscli.
      environment.etc."crowdsec/config.yaml".source =
        (pkgs.formats.yaml {}).generate "crowdsec.yaml" cfg.settings.general;

      services.crowdsec-firewall-bouncer = {
        enable = true;
        # Docker-published ports are DNATed through FORWARD and never reach
        # INPUT, so they need DOCKER-USER too.
        settings.iptables_chains = ["INPUT"] ++ lib.optional docker "DOCKER-USER";
      };

      # The setup script runs `cscli machines add` before `cscli capi
      # register`, and the former fails if the CAPI credentials file is
      # missing. An empty file loads as "no credentials" and register fills it.
      systemd.tmpfiles.settings."11-crowdsec-capi"."${stateDir}/online_api_credentials.yaml".f = {
        user = cfg.user;
        group = cfg.group;
        mode = "0600";
      };

      # The bouncer's registration unit is DynamicUser with StateDirectory
      # "crowdsec", so systemd moves /var/lib/crowdsec under /var/lib/private,
      # where crowdsec.service (no StateDirectory) can no longer reach it.
      systemd.services.crowdsec-firewall-bouncer-register.serviceConfig.DynamicUser = lib.mkForce false;

      # The bouncer Requires its registration unit but isn't ordered after it,
      # so on a fresh host it starts before its API key exists. Docker creates
      # DOCKER-USER; the bouncer skips a chain that's missing.
      # It also exits for good if the local API goes away, as it does whenever
      # crowdsec restarts, which would leave nothing enforcing.
      systemd.services.crowdsec-firewall-bouncer = {
        after = ["crowdsec-firewall-bouncer-register.service"] ++ lib.optional docker "docker.service";
        wants = lib.optional docker "docker.service";
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "10s";
        };
      };

      # Console enrolment. The module's console.tokenFile only enrols when the
      # token file is missing, so it never runs with the secret in place.
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
            # Pick up the console options enrol just wrote.
            systemctl --no-block try-restart crowdsec.service
          else
            echo "Console enrolment failed; the timer tries again in an hour." >&2
          fi
        '';
      };
      systemd.timers.crowdsec-console-enroll = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "2min";
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
        postOverflows = ["crowdsecurity/cdn-whitelist"];
      };
    };
  };
}
