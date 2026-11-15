{
  den,
  lib,
  ...
}: let
  inherit (den.lib.policy) pipe;

  sshPort = 2222;

  # Retention where the data lives and on the hub's copy. Long history is
  # the NAS's job.
  history = {
    hourly = 24;
    daily = 7;
    monthly = 0;
  };

  # A record is { name, dataset } plus, optionally:
  #   enable = false   drop a default (repeat its name)
  #   latest = true    keep only the newest daily: a recovery copy, no history
  #   sanoid = { .. }  any other per-dataset sanoid settings, on the host
  # One entry per name; any enable = false wins.
  resolve = records:
    lib.filter (d: d.enable) (lib.attrValues (lib.foldl' (acc: r:
      acc
      // {
        ${r.name} =
          {
            latest = false;
            sanoid = {};
          }
          // (acc.${r.name} or {})
          // r
          // {enable = (acc.${r.name}.enable or true) && (r.enable or true);};
      }) {}
    records));

  # One host's backup emissions, folded into { datasets, hostKey, hub }.
  merge = emissions: {
    datasets = resolve (lib.concatMap (e: e.datasets or []) emissions);
    hostKey = lib.findFirst (k: k != null) null (map (e: e.source.hostKey or null) emissions);
    hub = lib.findFirst (h: h != null) null (map (e: e.hub or null) emissions);
  };

  hostSanoid = d:
    {use_template = ["backup"];}
    // lib.optionalAttrs d.latest {
      hourly = 0;
      daily = 1;
    }
    // d.sanoid;
in {
  # A host's part in backups, from any of its aspects. Each emission is an
  # attrset with any of:
  #   datasets = [ record .. ]  ZFS datasets it offers
  #   source.hostKey = "..."    its sshd key (/etc/ssh/ssh_host_ed25519_key.pub);
  #                             required with datasets, and hubs refuse a host
  #                             that presents another key
  #   hub = { key; pool; }      it pulls every source into pool; key is the
  #                             public half of its pull key, whose private half
  #                             is the sops secret backupHubSshKey
  den.quirks.backup.description = "This host's part in backups: datasets, source key, hub";
  den.quirks.backup-fleet.description = "Every host's backup emissions, with provenance";

  # Sources need the hubs' keys and hubs need the sources, so every host sees
  # the whole fleet.
  den.policies.backup-fleet = {host, ...}: [
    (pipe.from "backup" [
      (pipe.collectAll ({host, ...}: true))
      pipe.withProvenance
      (pipe.as "backup-fleet")
    ])
  ];
  den.schema.host.includes = [den.policies.backup-fleet];

  den.aspects.backup.nixos = {
    backup,
    backup-fleet,
    config,
    lib,
    pkgs,
    ...
  }: let
    self = merge backup;
    name = config.networking.hostName;
    records = self.datasets;
    datasets = map (d: d.dataset) records;
    zfs = lib.getExe config.boot.zfs.package;

    fleet = lib.mapAttrsToList (_: rs: merge (map (r: r.value) rs) // {host = (lib.head rs).source.host;}) (lib.groupBy (r: r.source.host.name) backup-fleet);
    hubs = lib.filter (h: h.hub != null) fleet;
    sources = lib.filter (h: h.hostKey != null && h.datasets != []) fleet;

    # Hub side.
    pool = self.hub.pool;
    jobs = lib.sort (a: b: a.unit < b.unit) (lib.concatMap (h:
      map (d:
        d
        // {
          inherit (h) host hostKey;
          unit = "${h.host.name}-${d.name}";
          # Datasets with history and recovery-only copies sit in separate
          # trees, so the NAS can give each tree its own retention.
          tree = "${pool}/${
            if d.latest
            then "latest"
            else "hosts"
          }";
        })
      h.datasets)
    sources);
    remote = lib.filter (j: j.host.name != name) jobs;
    target = j: "${j.tree}/${j.host.name}/${j.name}";
    parents = lib.unique (lib.concatMap (j: [j.tree "${j.tree}/${j.host.name}"]) jobs);
    fqdn = h: "${h.name}.${h.tailnetSuffix}";
    # Spread the pulls across the hour: after sanoid's run on the hour, and
    # re-spaced whenever a job is added or removed.
    minute = i: 5 + (i * 50) / (lib.length jobs);
  in
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = (records != []) == (self.hostKey != null);
            message =
              if records != []
              then "backup: ${name} offers ${lib.concatStringsSep ", " datasets} but declares no backup.source.hostKey"
              else "backup: ${name} declares backup.source.hostKey but offers no datasets";
          }
          {
            assertion = records == [] || hubs != [];
            message = "backup: ${name} offers datasets but no host declares backup.hub";
          }
        ];
      }

      # Source side: snapshots, the pull login and its permissions, all from
      # the host's own records.
      (lib.mkIf (records != []) {
        services.sanoid = {
          enable = true;
          templates.backup =
            history
            // {
              autosnap = true;
              autoprune = true;
            };
          datasets = lib.listToAttrs (map (d: lib.nameValuePair d.dataset (hostSanoid d)) records);
        };

        # sshd also answers on a second port. Tailscale SSH owns port 22 on the
        # tailnet address, so this is how the hub reaches the real sshd. Only
        # 22 is opened in the firewall; traffic arriving over the tailnet is
        # governed by the tailnet policy instead.
        services.openssh.ports = [22 sshPort];
        services.openssh.openFirewall = false;
        networking.firewall.allowedTCPPorts = [22];

        # syncoid compresses and buffers the stream on both ends when these
        # are on the source's PATH; without them it sends uncompressed.
        environment.systemPackages = [pkgs.lzop pkgs.mbuffer];

        users.groups.backup = {};
        users.users.backup = {
          isSystemUser = true;
          group = "backup";
          useDefaultShell = true;
          openssh.authorizedKeys.keys = map (h: "restrict ${h.hub.key}") hubs;
        };

        # Permissions live on the dataset, so a restored or recreated dataset
        # needs them again; this runs on every boot, and on deploy when the
        # list changes (or by restarting the unit).
        systemd.services.backup-zfs-allow = {
          description = "Delegate send permissions on backed-up datasets";
          wantedBy = ["multi-user.target"];
          after = ["zfs-mount.service"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = lib.concatMapStringsSep "\n" (d: "${zfs} allow backup send,hold,release ${lib.escapeShellArg d}") datasets;
        };

        den.deploy.health = {
          requiredSystemdUnits = ["sanoid.timer" "backup-zfs-allow.service"];
          # Only the host's own datasets: on the hub, sanoid also lists received
          # copies, which do not exist until their first pull.
          requiredCommands.backup-datasets = "${zfs} list ${lib.escapeShellArgs datasets} >/dev/null";
        };
      })

      # Hub side: one pull per dataset, pruning of the received copies, and
      # snapshots on the parent datasets so a recursive pull on the NAS sees
      # every host.
      (lib.mkIf (self.hub != null) {
        sops.secrets.backupHubSshKey.owner = "syncoid";

        programs.ssh.knownHosts = lib.listToAttrs (map (j:
          lib.nameValuePair "backup-${j.host.name}" {
            hostNames = ["[${fqdn j.host}]:${toString sshPort}"];
            publicKey = j.hostKey;
          })
        remote);

        services.syncoid = {
          enable = true;
          sshKey = config.sops.secrets.backupHubSshKey.path;
          commonArgs = [
            "--no-sync-snap"
            "--no-rollback"
            "--use-hold"
            "--sshport=${toString sshPort}"
            "--sshoption=StrictHostKeyChecking=yes"
          ];
          localTargetAllow = ["create" "mount" "receive" "hold" "release"];
          commands = lib.listToAttrs (map (j:
            lib.nameValuePair j.unit {
              source =
                if j.host.name == name
                then j.dataset
                else "backup@${fqdn j.host}:${j.dataset}";
              target = target j;
              recvOptions = "u";
            })
          jobs);
        };

        systemd.timers = lib.listToAttrs (lib.imap0 (i: j:
          lib.nameValuePair "syncoid-${j.unit}" {
            timerConfig.OnCalendar = lib.mkForce "*:${lib.fixedWidthString 2 "0" (toString (minute i))}";
          })
        jobs);

        systemd.services =
          lib.listToAttrs (map (j:
            lib.nameValuePair "syncoid-${j.unit}" {
              serviceConfig = {
                Nice = 10;
                IOSchedulingClass = "idle";
              };
            })
          jobs)
          // {
            backup-hub-datasets = {
              description = "Create the parent datasets for received backups";
              wantedBy = ["multi-user.target"];
              before = map (j: "syncoid-${j.unit}.service") jobs;
              after = ["zfs-mount.service"];
              path = [config.boot.zfs.package];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = lib.concatMapStringsSep "\n" (p: "zfs list ${p} >/dev/null 2>&1 || zfs create -o canmount=off ${p}") parents;
            };
          };

        services.sanoid = {
          # Received copies: prune only. A recovery-only copy keeps two dailies,
          # so the NAS always shares one with the hub.
          templates.backup-copy =
            history
            // {
              autosnap = false;
              autoprune = true;
            };
          # Parent datasets: snapshots are required, or a recursive pull on the
          # NAS silently skips a host that has none.
          templates.backup-parent =
            history
            // {
              autosnap = true;
              autoprune = true;
            };
          datasets =
            lib.listToAttrs (map (j:
              lib.nameValuePair (target j) ({use_template = ["backup-copy"];}
                // lib.optionalAttrs j.latest {
                  hourly = 0;
                  daily = 2;
                }))
            jobs)
            // lib.genAttrs parents (_: {use_template = ["backup-parent"];});
        };

        # The newest snapshot of every dataset in both trees, parents included. A
        # pull with nothing to send still succeeds, so a stale copy only shows
        # here. A dataset with no snapshots reports 0.
        services.telegraf.extraConfig.inputs.exec = [
          {
            alias = "zfs_backup";
            commands = [
              (toString (pkgs.writeShellScript "zfs-backup-newest" ''
                ${zfs} list -Hp -r -t filesystem,snapshot -o name,creation \
                  ${lib.concatMapStringsSep " " (t: "${pool}/${t}") ["hosts" "latest"]} 2>/dev/null |
                  ${lib.getExe pkgs.gawk} -F '\t' '{
                    split($1, p, "@")
                    if (!(p[1] in t)) t[p[1]] = 0
                    if (p[2] != "" && $2 > t[p[1]]) t[p[1]] = $2
                  }
                  END { for (d in t) printf "zfs_backup,name=%s newest_snapshot_ts=%di\n", d, t[d] }'
              ''))
            ];
            timeout = "20s";
            data_format = "influx";
          }
        ];

        den.deploy.health.requiredSystemdUnits = ["backup-hub-datasets.service"];
      })
    ];
}
