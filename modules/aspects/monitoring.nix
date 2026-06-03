{ inputs, config, pkgs, lib, ... }: {
  den.aspects.monitoring = {
    nixos = { config, pkgs, lib, ... }: {
      imports = [
        # Use beszel-agent module from unstable (systemd monitoring support)
        "${inputs.nixpkgs-unstable}/nixos/modules/services/monitoring/beszel-agent.nix"
      ];

      # Disable the base nixpkgs beszel-agent module to avoid conflicts
      disabledModules = ["services/monitoring/beszel-agent.nix"];

      # Beszel Agent
      sops.secrets.beszelEnv = {};
      services.beszel.agent = {
        enable = lib.mkDefault true;
        package = pkgs.myPkgs.beszel;
        environmentFile = config.sops.secrets.beszelEnv.path;
        environment.SYSTEM_NAME = lib.mkDefault (lib.strings.toSentenceCase config.networking.hostName);
      };

      # Grafana Alloy
      sops.secrets.alloyEnv = {};
      services.alloy.enable = lib.mkDefault true;
      services.alloy.extraFlags = ["--stability.level=public-preview"];
      systemd.services.alloy = {
        environment.GCLOUD_FM_COLLECTOR_ID = config.networking.hostName;
        serviceConfig =
          {
            EnvironmentFile = config.sops.secrets.alloyEnv.path;
          }
          // lib.optionalAttrs config.virtualisation.docker.enable {
            # Root required for Alloy to run standalone cAdvisor
            User = "root";
            SupplementaryGroups = ["docker"];
          };
      };

      environment.etc."alloy/config.alloy".text = ''
        remotecfg {
          url            = sys.env("GCLOUD_FM_URL")
          id             = sys.env("GCLOUD_FM_COLLECTOR_ID")
          poll_frequency = sys.env("GCLOUD_FM_POLL_FREQUENCY")

          basic_auth {
            username = sys.env("GCLOUD_FM_HOSTED_ID")
            password = sys.env("GCLOUD_RW_API_KEY")
          }
        }
      '';

      # Netronome Speedtest Agent
      systemd.services.netronome = {
        description = "Netronome Agent - Network Speed Testing and Monitoring";
        documentation = ["https://github.com/autobrr/netronome"];
        after = ["network-online.target"];
        wants = ["network-online.target"];
        wantedBy = ["multi-user.target"];

        path = with pkgs; [
          iperf3
          librespeed-cli
          traceroute
          mtr
          vnstat
        ];

        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.myPkgs.netronome}/bin/netronome agent --tailscale";
          Restart = "always";
          RestartSec = 10;

          # Security hardening
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
        };
      };
    };
  };
}
