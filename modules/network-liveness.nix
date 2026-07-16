{lib, ...}: let
  networkLivenessModule = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.services.networkLiveness;
    checks = cfg.checks;
    checkCalls = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: check: "check_service ${lib.escapeShellArgs [
        name
        (toString check.maxIdleSeconds)
        (
          if check.inhibitPath == null
          then ""
          else check.inhibitPath
        )
        (toString check.inhibitMaxAgeSeconds)
      ]} || failed=1")
      checks);
  in {
    options.services.networkLiveness.checks = lib.mkOption {
      default = {};
      description = "Systemd services whose network ingress should be monitored for liveness.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          maxIdleSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            default = 180;
            description = "Seconds without ingress before the service is considered stale.";
          };

          inhibitPath = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional runtime path that temporarily inhibits recovery.";
          };

          inhibitMaxAgeSeconds = lib.mkOption {
            type = lib.types.ints.positive;
            default = 600;
            description = "Maximum age of an inhibitor before it is ignored.";
          };
        };
      });
    };

    config = lib.mkIf (checks != {}) {
      systemd.slices."-".sliceConfig.IPAccounting = true;

      systemd.services = lib.mkMerge [
        (lib.mapAttrs (_: _: {
            serviceConfig.IPAccounting = true;
          })
          checks)
        {
          network-liveness = {
            description = "Recover services whose network ingress has stalled";
            serviceConfig = {
              Type = "oneshot";
              RuntimeDirectory = "network-liveness";
              RuntimeDirectoryPreserve = true;
            };
            script = ''
              systemctl=${pkgs.systemd}/bin/systemctl
              date=${pkgs.coreutils}/bin/date
              stat=${pkgs.coreutils}/bin/stat
              mv=${pkgs.coreutils}/bin/mv
              now="$($date +%s)"

              is_number() {
                case "$1" in
                  ""|*[!0-9]*) return 1 ;;
                  *) return 0 ;;
                esac
              }

              write_state() {
                state=$1
                printf '%s %s %s %s\n' "$2" "$3" "$4" "$5" > "$state.tmp"
                $mv "$state.tmp" "$state"
              }

              check_service() {
                service=$1
                max_idle=$2
                inhibit_path=$3
                inhibit_max_age=$4
                unit="$service.service"
                state="$RUNTIME_DIRECTORY/$service"

                if ! $systemctl is-active --quiet "$unit"; then
                  return 0
                fi

                if ! accounting="$($systemctl show "$unit" --property=IPAccounting --value)" || [ "$accounting" != yes ]; then
                  echo "network-liveness: $unit does not have working IP accounting" >&2
                  return 1
                fi

                if ! invocation="$($systemctl show "$unit" --property=InvocationID --value)" || [ -z "$invocation" ]; then
                  echo "network-liveness: could not read $unit invocation ID" >&2
                  return 1
                fi

                if ! ingress="$($systemctl show "$unit" --property=IPIngressBytes --value)" || ! is_number "$ingress"; then
                  echo "network-liveness: could not read $unit ingress counter" >&2
                  return 1
                fi

                if [ ! -e "$state" ]; then
                  write_state "$state" "$invocation" "$ingress" "$now" "$machine_ingress"
                  return 0
                fi

                read -r old_invocation old_ingress last_change old_machine_ingress < "$state" || true
                if [ -z "$old_invocation" ] || ! is_number "$old_ingress" || ! is_number "$last_change" || ! is_number "$old_machine_ingress"; then
                  echo "network-liveness: replacing corrupt state for $unit" >&2
                  write_state "$state" "$invocation" "$ingress" "$now" "$machine_ingress"
                  return 1
                fi

                if [ "$invocation" != "$old_invocation" ] || [ "$ingress" != "$old_ingress" ]; then
                  write_state "$state" "$invocation" "$ingress" "$now" "$machine_ingress"
                  return 0
                fi

                idle=$((now - last_change))
                if [ "$idle" -lt "$max_idle" ] || [ "$machine_ingress" -le "$old_machine_ingress" ]; then
                  write_state "$state" "$invocation" "$ingress" "$last_change" "$machine_ingress"
                  return 0
                fi

                write_state "$state" "$invocation" "$ingress" "$last_change" "$machine_ingress"

                if [ -n "$inhibit_path" ] && [ -e "$inhibit_path" ]; then
                  if ! inhibit_mtime="$($stat -c %Y "$inhibit_path")" || ! is_number "$inhibit_mtime"; then
                    echo "network-liveness: could not inspect inhibitor for $unit: $inhibit_path" >&2
                    return 1
                  fi

                  inhibit_age=$((now - inhibit_mtime))
                  if [ "$inhibit_age" -le "$inhibit_max_age" ]; then
                    echo "network-liveness: restart of $unit inhibited by $inhibit_path" >&2
                    return 0
                  fi
                fi

                echo "network-liveness: restarting $unit after $idle seconds without ingress" >&2
                if ! $systemctl restart "$unit"; then
                  echo "network-liveness: failed to restart $unit" >&2
                  return 1
                fi
              }

              if ! machine_ingress="$($systemctl show --property=IPIngressBytes --value -- -.slice)" || ! is_number "$machine_ingress"; then
                echo "network-liveness: could not read machine ingress counter" >&2
                exit 1
              fi

              failed=0
              ${checkCalls}
              exit "$failed"
            '';
          };
        }
      ];

      systemd.timers.network-liveness = {
        description = "Periodically check service network liveness";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "1min";
        };
      };
    };
  };
in {
  den.default.nixos = networkLivenessModule;

  perSystem = {
    pkgs,
    system,
    ...
  }: {
    packages = lib.optionalAttrs (system == "x86_64-linux") {
      network-liveness-test = pkgs.testers.runNixOSTest {
        name = "network-liveness";

        nodes.machine = {
          lib,
          pkgs,
          ...
        }: {
          imports = [networkLivenessModule];

          services.networkLiveness.checks.target = {
            maxIdleSeconds = 1;
            inhibitPath = "/run/network-liveness-test-inhibit";
          };
          services.networkLiveness.checks.broken-witness = {};

          networking.useDHCP = false;
          systemd.timers.network-liveness.enable = lib.mkForce false;

          systemd.services.target = {
            wantedBy = ["multi-user.target"];
            serviceConfig.ExecStart = "${pkgs.python3}/bin/python -m http.server 8123 --bind 127.0.0.1";
          };

          systemd.services.broken-witness = {
            wantedBy = ["multi-user.target"];
            serviceConfig.ExecStart = "${pkgs.python3}/bin/python -m http.server 8124 --bind 127.0.0.1";
          };

          environment.systemPackages = [pkgs.curl];
        };

        testScript = ''
          machine.start()
          machine.wait_for_unit("target.service")
          machine.wait_for_unit("broken-witness.service")
          machine.wait_for_open_port(8123)
          machine.wait_for_open_port(8124)

          def invocation():
              return machine.succeed(
                  "systemctl show target.service --property=InvocationID --value"
              ).strip()

          machine.succeed("systemctl start network-liveness.service")
          initial_invocation = invocation()

          machine.sleep(2)
          machine.succeed("systemctl start network-liveness.service")
          assert invocation() == initial_invocation

          machine.succeed("curl --fail --silent http://127.0.0.1:8123 >/dev/null")
          machine.sleep(2)
          machine.succeed("systemctl start network-liveness.service")
          assert invocation() == initial_invocation

          machine.sleep(2)
          machine.succeed("curl --fail --silent http://127.0.0.1:8124 >/dev/null")
          machine.succeed("systemctl start network-liveness.service")
          restarted_invocation = invocation()
          assert restarted_invocation != initial_invocation

          machine.succeed("touch /run/network-liveness-test-inhibit")
          machine.succeed("systemctl start network-liveness.service")
          machine.sleep(2)
          machine.succeed("curl --fail --silent http://127.0.0.1:8124 >/dev/null")
          machine.succeed("systemctl start network-liveness.service")
          assert invocation() == restarted_invocation

          machine.succeed("touch --date=@1 /run/network-liveness-test-inhibit")
          machine.succeed("curl --fail --silent http://127.0.0.1:8124 >/dev/null")
          machine.succeed("systemctl start network-liveness.service")
          assert invocation() != restarted_invocation

          isolation_invocation = invocation()
          machine.succeed("systemctl start network-liveness.service")
          machine.succeed("printf corrupt > /run/network-liveness/broken-witness")
          machine.sleep(2)
          machine.succeed("curl --fail --silent http://127.0.0.1:8124 >/dev/null")
          machine.fail("systemctl start network-liveness.service")
          assert invocation() != isolation_invocation

          machine.succeed("systemctl stop target.service")
          machine.succeed("systemctl start network-liveness.service")
          machine.succeed("! systemctl is-active --quiet target.service")
        '';
      };
    };
  };
}
