{den, ...}: let
  inherit (den.lib.policy) pipe;
  queueDirectory = "/run/hci-store-replication";
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
        tmp="$(${pkgs.coreutils}/bin/mktemp /run/hci-store-replication.XXXXXXXX)" || {
          echo "hci-store-replication: could not create queue manifest" >&2
          exit 0
        }
        trap '${pkgs.coreutils}/bin/rm -f -- "$tmp"' EXIT

        # OUT_PATHS is space-separated; Nix store paths cannot contain spaces.
        # Globbing is disabled above so store-path punctuation stays literal.
        if ! ${pkgs.coreutils}/bin/printf '%s\n' $out_paths > "$tmp"; then
          echo "hci-store-replication: could not write queue manifest" >&2
          exit 0
        fi

        if ! ${pkgs.coreutils}/bin/mv -- "$tmp" "$queue/''${tmp##*/}"; then
          echo "hci-store-replication: could not enqueue output paths" >&2
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
          shopt -s nullglob

          queue=${lib.escapeShellArg queueDirectory}
          peers=(${lib.concatMapStringsSep " " ({source, ...}: lib.escapeShellArg "${source.host.name}.${source.host.tailnetSuffix}") hciStorePeers})
          export NIX_SSHOPTS=${lib.escapeShellArg "-i ${config.sops.secrets.hciStoreReplicationKey.path} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"}

          while :; do
            manifests=("$queue"/*)
            if ((''${#manifests[@]} == 0)); then
              exit 0
            fi

            batch="$(${pkgs.coreutils}/bin/mktemp /run/hci-store-replication-batch.XXXXXXXX)" || {
              echo "event=batch status=failed reason=mktemp" >&2
              exit 0
            }
            trap '${pkgs.coreutils}/bin/rm -f -- "$batch"' EXIT

            if ! ${pkgs.coreutils}/bin/sort -u -- "''${manifests[@]}" > "$batch"; then
              echo "event=batch status=failed reason=sort" >&2
              exit 0
            fi

            if [ ! -s "$batch" ]; then
              ${pkgs.coreutils}/bin/rm -f -- "''${manifests[@]}" "$batch"
              trap - EXIT
              continue
            fi

            path_count="$(${pkgs.coreutils}/bin/wc -l < "$batch" | ${pkgs.coreutils}/bin/tr -d ' ')"
            echo "event=batch status=start paths=$path_count peers=''${#peers[@]} manifests=''${#manifests[@]}"

            pids=()
            for peer in "''${peers[@]}"; do
              (
                echo "event=copy status=start peer=$peer paths=$path_count"
                if ${config.nix.package}/bin/nix copy \
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

            ${pkgs.coreutils}/bin/rm -f -- "''${manifests[@]}" "$batch"
            trap - EXIT

            echo "event=batch status=complete paths=$path_count peers=''${#peers[@]} failures=$failures"
          done
        '';
      };
    };
  };
}
