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
          pkgs.gawk
          pkgs.jq
          config.boot.zfs.package
        ];
        text = ''
          set -eu

          output=/var/lib/alloy/zfs.prom
          last_success=/var/lib/alloy/zfs-scrub-last-success.json
          status_tmp="$(mktemp /var/lib/alloy/zfs-status.XXXXXX)"
          objects_tmp="$(mktemp /var/lib/alloy/zfs-objects.XXXXXX)"
          monitor_tmp="$(mktemp /var/lib/alloy/zfs-monitor.XXXXXX)"
          metrics_tmp="$(mktemp /var/lib/alloy/zfs.prom.XXXXXX)"
          last_tmp="$(mktemp /var/lib/alloy/zfs-scrub-last-success.XXXXXX)"
          trap 'rm -f "$status_tmp" "$objects_tmp" "$monitor_tmp" "$metrics_tmp" "$last_tmp"' EXIT

          zpool status -j -p > "$status_tmp"
          zfs list -H -p -t filesystem,volume \
            -o name,type,used,available,usedbydataset,usedbysnapshots,usedbychildren,quota,refquota \
            > "$objects_tmp"
          zfs get -H -p -o name,value,source -s local -t filesystem,volume \
            grafana:monitor > "$monitor_tmp"
          if ! test -s "$last_success"; then
            printf '{}\n' > "$last_success"
          fi

          jq --slurpfile previous "$last_success" '
            reduce (.pools | to_entries[]) as $pool ($previous[0];
              if (($pool.value.scan_stats.function // "") == "SCRUB"
                  and ($pool.value.scan_stats.state // "") == "FINISHED"
                  and (($pool.value.scan_stats.errors // "0") | tonumber) == 0)
              then .[$pool.key] = (($pool.value.scan_stats.end_time // "0") | tonumber)
              else .
              end
            )
          ' "$status_tmp" > "$last_tmp"
          mv "$last_tmp" "$last_success"

          jq -r --slurpfile last "$last_success" '
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

          chmod 0644 "$metrics_tmp"
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
      # Grafana Alloy
      sops.secrets.alloyEnv = {};
      services.alloy.enable = lib.mkDefault true;
      services.alloy.extraFlags = ["--stability.level=public-preview"];
      services.prometheus.exporters.smartctl.enable = true;
      services.prometheus.exporters.smartctl.listenAddress = "127.0.0.1";
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
        description = "Export bounded ZFS pool and object metrics for Alloy";
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
        };
      };

      systemd.timers.alloy-zfs-metrics = lib.mkIf config.boot.zfs.enabled {
        description = "Refresh bounded ZFS pool and object metrics for Alloy";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "1m";
          AccuracySec = "1s";
          RandomizedDelaySec = "5s";
          Persistent = true;
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
