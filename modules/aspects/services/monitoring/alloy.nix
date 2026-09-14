{...}: {
  den.aspects.alloy = {
    nixos = {
      config,
      lib,
      pkgs,
      ...
    }: let
      telemetry = config.services.alloy.telemetry;
      cadvisorEnabled = telemetry.cadvisorMode != "legacy";
      zfsExporterEnabled = telemetry.zfsMode != "legacy";
      fleetTelemetryAttributes =
        lib.optionalString cadvisorEnabled "\n    \"telemetry.cadvisor\" = \"${telemetry.cadvisorMode}\","
        + lib.optionalString zfsExporterEnabled "\n    \"telemetry.zfs\" = \"${telemetry.zfsMode}\",";
      zfsMetrics = pkgs.writeShellApplication {
        name = "alloy-zfs-metrics";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gawk
          pkgs.jq
          config.boot.zfs.package
        ];
        text = ''
          set -eu

          output=/var/lib/alloy/zfs.prom
          last_success=/var/lib/alloy/zfs-scrub-last-success.json
          mode=${lib.escapeShellArg telemetry.zfsMode}
          status_tmp="$(mktemp /var/lib/alloy/zfs-status.XXXXXX)"
          objects_tmp="$(mktemp /var/lib/alloy/zfs-objects.XXXXXX)"
          monitor_tmp="$(mktemp /var/lib/alloy/zfs-monitor.XXXXXX)"
          metrics_tmp="$(mktemp /var/lib/alloy/zfs.prom.XXXXXX)"
          last_tmp="$(mktemp /var/lib/alloy/zfs-scrub-last-success.XXXXXX)"
          trap 'rm -f "$status_tmp" "$objects_tmp" "$monitor_tmp" "$metrics_tmp" "$last_tmp"' EXIT

          zpool status -j -p > "$status_tmp"
          if test "$mode" != standalone; then
            zfs list -H -p -t filesystem,volume \
              -o name,type,used,available,usedbydataset,usedbysnapshots,usedbychildren,quota,refquota \
              > "$objects_tmp"
            zfs get -H -p -o name,value,source -s local -t filesystem,volume \
              grafana:monitor > "$monitor_tmp"
          fi

          previous="$last_success"
          if ! test -s "$previous"; then
            previous_tmp="$(mktemp /var/lib/alloy/zfs-scrub-previous.XXXXXX)"
            trap 'rm -f "$status_tmp" "$objects_tmp" "$monitor_tmp" "$metrics_tmp" "$last_tmp" "$previous_tmp"' EXIT
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

          if test "$mode" = standalone; then
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
          else
            jq -r --slurpfile last "$last_tmp" '
            .pools | to_entries[] |
            .key as $pool |
            .value as $status |
            ($status.vdevs[$pool] // {}) as $root |
            def metric($name; $value):
              "\($name){pool=\($pool | @json)} \($value)";
            metric("homelab_zfs_pool_healthy";
              if $status.state == "ONLINE" then 1 else 0 end),
            metric("homelab_zfs_pool_allocated_bytes";
              (($root.alloc_space // "0") | tonumber)),
            metric("homelab_zfs_pool_free_bytes";
              ((($root.total_space // "0") | tonumber)
               - (($root.alloc_space // "0") | tonumber))),
            metric("homelab_zfs_pool_read_errors_total";
              (($root.read_errors // "0") | tonumber)),
            metric("homelab_zfs_pool_write_errors_total";
              (($root.write_errors // "0") | tonumber)),
            metric("homelab_zfs_pool_checksum_errors_total";
              (($root.checksum_errors // "0") | tonumber)),
            metric("homelab_zfs_pool_scrub_running";
              if ($status.scan_stats.state // "") == "SCANNING" then 1 else 0 end),
            metric("homelab_zfs_pool_scrub_last_success_timestamp_seconds";
              ($last[0][$pool] // 0))
            ' "$status_tmp" > "$metrics_tmp"

            awk -F '	' -v monitor_file="$monitor_tmp" '
            FILENAME == monitor_file {
              if ($2 == "include" || $2 == "exclude") {
                monitor[$1] = $2
              }
              next
            }
            {
              name = $1
              type = $2
              pool = name
              sub(/\/.*/, "", pool)
              selection = monitor[name]
              if (selection == "") {
                selection = "auto"
              }
              if ($8 != "0" && $8 != "-" && $8 != "none") {
                headroom = "quota"
              } else if ($9 != "0" && $9 != "-" && $9 != "none") {
                headroom = "refquota"
              } else {
                headroom = "pool"
              }
              labels = sprintf("{name=\"%s\",pool=\"%s\",type=\"%s\",monitor=\"%s\",headroom=\"%s\"}", name, pool, type, selection, headroom)
              print "homelab_zfs_object_used_bytes" labels " " $3
              print "homelab_zfs_object_available_bytes" labels " " $4
              print "homelab_zfs_object_usedbydataset_bytes" labels " " $5
              print "homelab_zfs_object_usedbysnapshots_bytes" labels " " $6
              print "homelab_zfs_object_usedbychildren_bytes" labels " " $7
            }
            ' "$monitor_tmp" "$objects_tmp" >> "$metrics_tmp"
          fi

          chmod 0644 "$metrics_tmp"
          mv "$last_tmp" "$last_success"
          mv "$metrics_tmp" "$output"
        '';
      };
      hostInfoMetrics = pkgs.writeShellApplication {
        name = "alloy-host-info";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.systemd
        ];
        text = ''
          set -eu

          output=/var/lib/alloy/host-info.prom
          temporary="$(mktemp /var/lib/alloy/host-info.prom.XXXXXX)"
          trap 'rm -f "$temporary"' EXIT

          virtualisation="$(systemd-detect-virt 2>/dev/null || true)"
          case "$virtualisation" in
            ""|none) platform=bare-metal ;;
            kvm|qemu) platform=qemu-kvm ;;
            *) platform="$virtualisation" ;;
          esac

          printf 'homelab_host_info{platform="%s",os="nixos",os_release="${config.system.nixos.release}"} 1\n' \
            "$platform" > "$temporary"
          chmod 0644 "$temporary"
          mv "$temporary" "$output"
        '';
      };
    in {
      imports = [
        {
          options.services.alloy.telemetry = {
            cadvisorMode = lib.mkOption {
              type = lib.types.enum [
                "legacy"
                "canary"
                "standalone"
              ];
              default = "legacy";
              description = "Migration mode for cAdvisor telemetry.";
            };

            zfsMode = lib.mkOption {
              type = lib.types.enum [
                "legacy"
                "canary"
                "standalone"
              ];
              default = "legacy";
              description = "Migration mode for ZFS telemetry.";
            };
          };
        }
      ];

      assertions = [
        {
          assertion = !cadvisorEnabled || config.virtualisation.docker.enable;
          message = "services.alloy.telemetry.cadvisorMode requires Docker when set to canary or standalone";
        }
        {
          assertion = !zfsExporterEnabled || config.boot.zfs.enabled;
          message = "services.alloy.telemetry.zfsMode requires ZFS when set to canary or standalone";
        }
      ];

      # Grafana Alloy
      sops.secrets.alloyEnv = {};
      services.alloy.enable = lib.mkDefault true;
      services.alloy.extraFlags = ["--stability.level=public-preview"];
      services.cadvisor = lib.mkIf cadvisorEnabled {
        enable = true;
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
      services.prometheus.exporters.zfs = lib.mkIf zfsExporterEnabled {
        enable = true;
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
        preStart = lib.getExe hostInfoMetrics;
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
          lib.optional cadvisorEnabled "cadvisor.service"
          ++ lib.optional zfsExporterEnabled "prometheus-zfs-exporter.service";
        requiredCommands =
          lib.optionalAttrs cadvisorEnabled {
            cadvisor = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 5 http://127.0.0.1:8080/metrics >/dev/null";
          }
          // lib.optionalAttrs zfsExporterEnabled {
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
            "telemetry.tailscale" = "${lib.boolToString config.services.tailscale.enable}",${fleetTelemetryAttributes}
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
