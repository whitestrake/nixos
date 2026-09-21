{...}: {
  den.aspects.alloy = {
    nixos = {
      config,
      lib,
      pkgs,
      ...
    }: {
      # Grafana Alloy
      sops.secrets.alloyEnv = {};
      services.alloy.enable = lib.mkDefault true;
      services.alloy.extraFlags = ["--stability.level=public-preview"];
      services.telegraf = {
        enable = true;
        extraConfig = {
          agent = {
            interval = "60s";
            flush_interval = "5s";
            omit_hostname = true;
            skip_processors_after_aggregators = true;
          };
          inputs = lib.filterAttrs (_: inputs: inputs != []) {
            docker = lib.optionals config.virtualisation.docker.enable [
              {
                endpoint = "unix:///var/run/docker.sock";
                source_tag = true;
                startup_error_behavior = "retry";
                timeout = "5s";
                perdevice_include = ["network"];
                total_include = ["cpu"];
                docker_label_exclude = ["*"];
                namepass = ["docker_container_cpu" "docker_container_mem" "docker_container_net" "docker_container_status" "docker_container_health"];
                fieldinclude = ["usage_total" "usage" "limit" "rx_bytes" "tx_bytes" "rx_errors" "tx_errors" "rx_dropped" "tx_dropped" "uptime_ns" "health_status" "failing_streak"];
                taginclude = ["container_name" "source" "cpu" "network"];
              }
            ];
            smart = [
              {
                path_smartctl = "${lib.getExe pkgs.smartmontools}";
                timeout = "20s";
                attributes = false;
                namepass = ["smart_device"];
                fieldinclude = ["health_ok" "exit_status" "critical_warning" "media_errors" "available_spare" "available_spare_threshold" "percentage_used" "temp_c"];
                taginclude = ["device"];
                path_nvme = "${lib.getExe pkgs.nvme-cli}";
                enable_extensions = [];
              }
            ];
            exec = lib.optionals config.boot.zfs.enabled [
              {
                alias = "zfs_pool";
                commands = ["${lib.getBin config.boot.zfs.package}/libexec/zfs/zpool_influxdb -n"];
                timeout = "20s";
                data_format = "influx";
                namepass = ["zpool_stats" "zpool_scan_stats"];
                fieldinclude = ["alloc" "free" "read_errors" "write_errors" "checksum_errors" "end_ts" "errors"];
                taginclude = ["name" "state" "vdev" "function"];
                tagdrop = {vdev = ["root/*"];};
              }
              {
                alias = "zfs_dataset";
                commands = ["${lib.getBin config.boot.zfs.package}/bin/zfs list -Hp -t filesystem,volume -o name,type,used,available,usedbydataset,usedbysnapshots,usedbychildren"];
                timeout = "20s";
                data_format = "csv";
                name_override = "zfs_dataset";
                csv_header_row_count = 0;
                csv_delimiter = "\t";
                csv_column_names = ["name" "type" "used" "available" "usedbydataset" "usedbysnapshots" "usedbychildren"];
                csv_column_types = ["string" "string" "int" "int" "int" "int" "int"];
                csv_tag_columns = ["name" "type"];
                csv_skip_values = ["-"];
                tagpass = {name = ["*/*"];};
              }
            ];
            internal = [
              {
                collect_memstats = false;
                namepass = ["internal_gather"];
                fieldinclude = ["errors" "metrics_gathered"];
                taginclude = ["input" "alias"];
              }
            ];
          };
          outputs = {
            prometheus_client = [
              {
                listen = "127.0.0.1:9273";
                metric_version = 1;
                string_as_label = true;
                export_timestamp = true;
                expiration_interval = "180s";
                collectors_exclude = ["gocollector" "process"];
              }
            ];
          };
          processors = {
            override = [
              {
                namepass = ["docker_container_cpu" "docker_container_mem" "docker_container_net"];
                tagexclude = ["source"];
              }
            ];
            converter = [
              {
                namepass = ["smart_device"];
                fields = {integer = ["health_ok"];};
              }
            ];
          };
        };
      };
      systemd.services.telegraf.serviceConfig = {
        # smartctl ioctls and Docker access require privileged collection.
        User = lib.mkForce "root";
        Group = lib.mkForce "root";
        AmbientCapabilities = lib.mkForce [];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
      systemd.services.alloy = {
        environment.GCLOUD_FM_COLLECTOR_ID = config.networking.hostName;
        serviceConfig =
          {
            EnvironmentFile = config.sops.secrets.alloyEnv.path;
          }
          // lib.optionalAttrs config.virtualisation.docker.enable {
            # Root required for Alloy to discover Docker containers and read their logs
            User = "root";
            SupplementaryGroups = ["docker"];
          };
      };

      den.deploy.health = {
        requiredSystemdUnits = ["telegraf.service"];
        requiredCommands.telegraf = ''
          ${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 5 http://127.0.0.1:9273/metrics >/dev/null &&
          ${config.systemd.services.telegraf.serviceConfig.ExecStart} --test >/dev/null
        '';
      };

      environment.etc."alloy/config.alloy".text = ''
        remotecfg {
          url            = sys.env("GCLOUD_FM_URL")
          id             = sys.env("GCLOUD_FM_COLLECTOR_ID")
          poll_frequency = sys.env("GCLOUD_FM_POLL_FREQUENCY")

          attributes = {
            "telemetry.docker" = "${lib.boolToString config.virtualisation.docker.enable}",
            "telemetry.tailscale" = "${lib.boolToString config.services.tailscale.enable}",
            "telemetry.zfs" = "${lib.boolToString config.boot.zfs.enabled}",
          }

          basic_auth {
            username = sys.env("GCLOUD_FM_HOSTED_ID")
            password = sys.env("GCLOUD_RW_API_KEY")
          }
        }
      '';
    };
  };
}
