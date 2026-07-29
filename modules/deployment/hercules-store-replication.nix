{den, ...}: let
  inherit (den.lib.policy) pipe;
  queueDirectory = "/nix/var/nix/gcroots/hci-store-replication";
  minimumRetrySeconds = 60;
  maximumRetrySeconds = 3600;
  maximumRetentionSeconds = 86400;
in {
  den.quirks.hciStorePeers.description = "Hercules CI store replication membership";

  den.aspects.hercules.store-replication = {
    hciStorePeers = {};

    includes = [
      (den.lib.policy.mkPolicy "collect-hci-store-peers" (
        local @ {host, ...}: [
          (pipe.from "hciStorePeers" [
            (pipe.filter (_: false))
            (pipe.collectAll (peer @ {host, ...}: peer.host.name != local.host.name))
            pipe.withProvenance
          ])
        ]
      ))
    ];

    nixos = {
      config,
      hciStorePeers ? [],
      lib,
      pkgs,
      ...
    }: {
      nix.sshServe = {
        enable = true;
        protocol = "ssh-ng";
        trusted = true;
        keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAKRU+tWgKjTeQjA4WI3SykLnO14dvUiY7UG5dbz7CUV hci-store-replication"];
      };

      services.hercules-ci-agent.settings.nixSettings.post-build-hook = pkgs.writeShellScript "hci-store-replication-queue-hook" ''
        set -u
        set -f

        queue=${lib.escapeShellArg queueDirectory}
        out_paths="''${OUT_PATHS:-}"

        if [ -z "$out_paths" ]; then
          exit 0
        fi

        umask 077
        root="$queue/root.$BASHPID.$RANDOM"
        while [ -e "$root" ] || [ -L "$root" ]; do
          root="$queue/root.$BASHPID.$RANDOM"
        done

        # Register all outputs in one Nix call so they remain live even if GC
        # overlaps the handoff to the asynchronous replication worker.
        if ! ${config.nix.package}/bin/nix-store \
          --add-root "$root" \
          --realise $out_paths \
          >/dev/null; then
          echo "hci-store-replication: could not root queued output paths" >&2
        fi

        exit 0
      '';

      systemd.tmpfiles.rules = [
        "d ${queueDirectory} 0700 root root -"
      ];

      systemd.paths.hci-store-replication = {
        description = "Watch for Hercules CI store replication work";
        wantedBy = ["multi-user.target"];
        pathConfig = {
          DirectoryNotEmpty = queueDirectory;
        };
      };

      sops.secrets.hciStoreReplicationKey = {};
      systemd.services.hci-store-replication = {
        description = "Replicate Hercules CI build outputs to peer agents";
        after = ["network-online.target"];
        wants = ["network-online.target"];
        restartIfChanged = false;
        path = [pkgs.openssh];

        # ponytail: one worker serializes batches; split per peer only if measured.
        serviceConfig = {
          Type = "oneshot";
          TimeoutStartSec = "infinity";
          Nice = 19;
          IOSchedulingClass = "idle";
          IOSchedulingPriority = 7;
          CPUWeight = 10;
          IOWeight = 10;
        };

        script = ''
          set -u
          set -o pipefail
          shopt -s nullglob

          queue=${lib.escapeShellArg queueDirectory}
          peers=(${lib.concatMapStringsSep " " ({source, ...}: lib.escapeShellArg "${source.host.name}.${source.host.tailnetSuffix}") hciStorePeers})
          export NIX_SSHOPTS=${lib.escapeShellArg "-i ${config.sops.secrets.hciStoreReplicationKey.path} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"}

          wait_to_retry() {
            local age now remaining retry_delay

            now="$(${pkgs.coreutils}/bin/date +%s)"
            age=$((now - oldest_queued_at))
            remaining=$((${toString maximumRetentionSeconds} - age))
            if ((remaining <= 0)); then
              return
            fi

            retry_delay=$age
            if ((retry_delay < ${toString minimumRetrySeconds})); then
              retry_delay=${toString minimumRetrySeconds}
            elif ((retry_delay > ${toString maximumRetrySeconds})); then
              retry_delay=${toString maximumRetrySeconds}
            fi
            if ((retry_delay > remaining)); then
              retry_delay=$remaining
            fi

            echo "event=batch status=waiting age_seconds=$age retry_seconds=$retry_delay"
            ${pkgs.coreutils}/bin/sleep "$retry_delay"
          }

          while :; do
            roots=("$queue"/*)
            if ((''${#roots[@]} == 0)); then
              exit 0
            fi

            now="$(${pkgs.coreutils}/bin/date +%s)"
            oldest_queued_at=
            retained_roots=()
            for root in "''${roots[@]}"; do
              queued_at="$(${pkgs.coreutils}/bin/stat -c %Y -- "$root" 2>/dev/null || true)"

              if [ ! -L "$root" ] || [ -z "$queued_at" ]; then
                echo "event=queue status=expired reason=invalid-root root=$root" >&2
                ${pkgs.coreutils}/bin/rm -f -- "$root"
                continue
              fi

              age=$((now - queued_at))
              if ((age >= ${toString maximumRetentionSeconds})); then
                target="$(${pkgs.coreutils}/bin/readlink -- "$root" 2>/dev/null || true)"
                echo "event=queue status=expired reason=max-age path=''${target:-unknown} age_seconds=$age" >&2
                ${pkgs.coreutils}/bin/rm -f -- "$root"
                continue
              fi

              if [ -z "$oldest_queued_at" ] || ((queued_at < oldest_queued_at)); then
                oldest_queued_at=$queued_at
              fi
              retained_roots+=("$root")
            done
            roots=("''${retained_roots[@]}")

            if ((''${#roots[@]} == 0)); then
              exit 0
            fi

            if ! batch="$(${pkgs.coreutils}/bin/mktemp /run/hci-store-replication-batch.XXXXXXXX)"; then
              echo "event=batch status=failed reason=mktemp" >&2
              wait_to_retry
              continue
            fi
            trap '${pkgs.coreutils}/bin/rm -f -- "$batch"' EXIT

            if ! ${pkgs.coreutils}/bin/readlink -- "''${roots[@]}" | ${pkgs.coreutils}/bin/sort -u > "$batch"; then
              echo "event=batch status=failed reason=read-roots" >&2
              ${pkgs.coreutils}/bin/rm -f -- "$batch"
              trap - EXIT
              wait_to_retry
              continue
            fi

            if [ ! -s "$batch" ]; then
              ${pkgs.coreutils}/bin/rm -f -- "''${roots[@]}" "$batch"
              trap - EXIT
              continue
            fi

            path_count="$(${pkgs.coreutils}/bin/wc -l < "$batch" | ${pkgs.coreutils}/bin/tr -d ' ')"
            echo "event=batch status=start paths=$path_count peers=''${#peers[@]} roots=''${#roots[@]}"

            now="$(${pkgs.coreutils}/bin/date +%s)"
            copy_timeout=$((oldest_queued_at + ${toString maximumRetentionSeconds} - now))
            if ((copy_timeout <= 0)); then
              ${pkgs.coreutils}/bin/rm -f -- "$batch"
              trap - EXIT
              continue
            elif ((copy_timeout > ${toString maximumRetrySeconds})); then
              copy_timeout=${toString maximumRetrySeconds}
            fi

            pids=()
            for peer in "''${peers[@]}"; do
              (
                echo "event=copy status=start peer=$peer paths=$path_count"
                if ${pkgs.coreutils}/bin/timeout --signal=KILL "$copy_timeout" \
                  ${lib.getExe config.nix.package} copy \
                  --no-check-sigs \
                  --to "ssh-ng://nix-ssh@$peer" \
                  --stdin \
                  < "$batch"; then
                  echo "event=copy status=complete peer=$peer paths=$path_count"
                else
                  status=$?
                  echo "event=copy status=failed peer=$peer paths=$path_count exit_status=$status" >&2
                  exit "$status"
                fi
              ) &
              pids+=("$!")
            done

            failures=0
            for pid in "''${pids[@]}"; do
              if ! wait "$pid"; then
                failures=$((failures + 1))
              fi
            done

            if ((failures == 0)); then
              ${pkgs.coreutils}/bin/rm -f -- "''${roots[@]}" "$batch"
              trap - EXIT
              echo "event=batch status=complete paths=$path_count peers=''${#peers[@]} failures=0"
              continue
            fi

            ${pkgs.coreutils}/bin/rm -f -- "$batch"
            trap - EXIT
            echo "event=batch status=retry paths=$path_count peers=''${#peers[@]} failures=$failures" >&2
            wait_to_retry
          done
        '';
      };
    };
  };
}
