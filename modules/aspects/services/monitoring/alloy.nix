{...}: {
  den.aspects.alloy = {
    nixos = {
      config,
      lib,
      pkgs,
      ...
    }: let
      zfsMetrics = pkgs.writeShellApplication {
        name = "alloy-zfs-metrics";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
          config.boot.zfs.package
        ];
        text = ''
          set -eu

          output=/var/lib/alloy/zfs.prom
          last_success=/var/lib/alloy/zfs-scrub-last-success.json
          status_tmp="$(mktemp /var/lib/alloy/zfs-status.XXXXXX)"
          metrics_tmp="$(mktemp /var/lib/alloy/zfs.prom.XXXXXX)"
          last_tmp="$(mktemp /var/lib/alloy/zfs-scrub-last-success.XXXXXX)"
          trap 'rm -f "$status_tmp" "$metrics_tmp" "$last_tmp"' EXIT

          zpool status -j -p > "$status_tmp"
          previous="$last_success"
          if ! test -s "$previous"; then
            previous_tmp="$(mktemp /var/lib/alloy/zfs-scrub-previous.XXXXXX)"
            trap 'rm -f "$status_tmp" "$metrics_tmp" "$last_tmp" "$previous_tmp"' EXIT
            printf '{}\n' > "$previous_tmp"
            previous="$previous_tmp"
          fi

          jq --slurpfile previous "$previous" '
            reduce (.pools | to_entries[]) as $pool ($previous[0];
              ($pool.value.scan_stats // {}) as $scan |
              (($scan.errors // null) | try tonumber catch null) as $errors |
              (($scan.end_time // null) | try tonumber catch null) as $end_time |
              if (($scan.function // "") == "SCRUB"
                  and ($scan.state // "") == "FINISHED"
                  and $errors != null
                  and $errors == 0
                  and $end_time != null)
              then .[$pool.key] = $end_time
              else .
              end
            )
          ' "$status_tmp" > "$last_tmp"

          jq -r --slurpfile last "$last_tmp" '
            def metric($pool; $name; $value):
              "\($name){pool=\($pool | @json)} \($value)";
            def required_number($value; $field):
              if $value == null then error("missing " + $field)
              else try ($value | tonumber) catch error("invalid " + $field)
              end;
            if ((.pools? | type) != "object" or (.pools | length) == 0)
            then error("no ZFS pools returned")
            else
              .pools | to_entries[] |
              .key as $pool |
              .value as $status |
              (($status.vdevs // {})[$pool] // error("missing root vdev for " + $pool)) as $root |
              required_number($root.read_errors; "read_errors") as $read_errors |
              required_number($root.write_errors; "write_errors") as $write_errors |
              required_number($root.checksum_errors; "checksum_errors") as $checksum_errors |
              metric($pool; "zfs_pool_read_errors_total"; $read_errors),
              metric($pool; "zfs_pool_write_errors_total"; $write_errors),
              metric($pool; "zfs_pool_checksum_errors_total"; $checksum_errors),
              metric($pool; "zfs_pool_scrub_last_success_timestamp_seconds";
                ($last[0][$pool] // 0))
            end
          ' "$status_tmp" > "$metrics_tmp"
          printf 'zfs_incident_collection_last_success_timestamp_seconds %s\n' "$(date +%s)" >> "$metrics_tmp"

          chmod 0644 "$metrics_tmp"
          mv "$last_tmp" "$last_success"
          mv "$metrics_tmp" "$output"
        '';
      };
    in {
      # Grafana Alloy
      sops.secrets.alloyEnv = {};
      services.alloy.enable = lib.mkDefault true;
      services.alloy.extraFlags = ["--stability.level=public-preview"];
      services.cadvisor = {
        enable = config.virtualisation.docker.enable;
        listenAddress = "127.0.0.1";
        port = 8080;
        extraOptions = [
          "--storage_duration=2m"
          "--docker_only=true"
          "--containerd=/run/docker/containerd/containerd.sock"
          "--disable_root_cgroup_stats=true"
          "--store_container_labels=false"
          "--enable_metrics=cpu,memory,network"
        ];
      };
      services.prometheus.exporters.smartctl.enable = true;
      services.prometheus.exporters.smartctl.listenAddress = "127.0.0.1";
      services.prometheus.exporters.zfs = {
        enable = config.boot.zfs.enabled;
        listenAddress = "127.0.0.1";
        port = 9134;
        extraFlags = [
          "--collector.dataset-filesystem"
          "--properties.dataset-filesystem=used,available,usedbydataset,usedbysnapshots,usedbychildren"
          "--no-collector.dataset-snapshot"
          "--exclude=^[^/]+$"
          "--collector.dataset-volume"
          "--properties.dataset-volume=used,available,usedbydataset,usedbysnapshots,usedbychildren"
          "--collector.pool"
          "--properties.pool=allocated,free,health"
        ];
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

      systemd.services.alloy-zfs-metrics = lib.mkIf config.boot.zfs.enabled {
        description = "Export bounded ZFS metrics for Alloy";
        after = [
          "alloy.service"
          "zfs-import.target"
        ];
        requires = ["alloy.service"];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
          UMask = "0022";
          ExecStart = lib.getExe zfsMetrics;
          TimeoutStartSec = "45s";
        };
      };

      systemd.timers.alloy-zfs-metrics = lib.mkIf config.boot.zfs.enabled {
        description = "Refresh bounded ZFS metrics for Alloy";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "1m";
          AccuracySec = "1s";
          RandomizedDelaySec = "5s";
          Persistent = true;
        };
      };

      den.deploy.health = {
        requiredSystemdUnits =
          lib.optional config.virtualisation.docker.enable "cadvisor.service"
          ++ lib.optional config.boot.zfs.enabled "prometheus-zfs-exporter.service";
        requiredCommands =
          lib.optionalAttrs config.virtualisation.docker.enable {
            cadvisor = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 5 http://127.0.0.1:8080/metrics >/dev/null";
          }
          // lib.optionalAttrs config.boot.zfs.enabled {
            zfs-exporter = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 5 http://127.0.0.1:9134/metrics >/dev/null";
          };
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
