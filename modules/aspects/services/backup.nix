{
  den,
  lib,
  ...
}: let
  inherit (den.lib.policy) pipe;

  hub = "omnius";
  sshPort = 2222;
  hubPool = "storage/backups";

  # Public half of the hub's pull key. The private half is the sops secret
  # backupHubSshKey, used on the hub only.
  hubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJkuhamEZxf1cBneOeKSnpKQxxscay4RlsMbQXclee5c backup-hub";

  # Each host's sshd key (/etc/ssh/ssh_host_ed25519_key.pub). The hub refuses
  # to pull from a host that presents another key, so a reinstalled host
  # needs its new key here.
  hostKeys = {
    jaeger = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGf2XboT4/Cw/bVx7UJFDeWlV3gERPexJshACHRe9jcv";
    legion = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJRNcVR6nToY6BaV7oAWgnQlny4QBQvhO7g/Moy2Zusk";
    oculus = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA8dULaxAaqFw4Jo3kaRykz7GyZ7zZS2qwrmo+623kfb";
    onager = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICjab5VQJMOExAY9c4raC+tL9S5hYoGs/7cxUpG88oyn";
    orthus = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4b2cazWukt8vr4EtkRxooRBHka+0UuMI9Rz9iykwtW";
    pascal = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKgAWQ4IWoSWBiviLxFS+SIozuL1x2Dd0dvzMBJQ/XBG";
    rapier = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEOSBgM0RLrG8kzg2MIo4BTgN3BIdF8bfSIg636tiRmP";
    sortie = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILQ8dN9LDgcgBgXVqZj18EelVapPLcpWn80HgeC87Fg9";
  };

  # Hosts the hub pulls from. Every host snapshots its own datasets either
  # way; only these are copied to the hub.
  pulled = ["legion" "pascal"];

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

  hostSanoid = d:
    {use_template = ["backup"];}
    // lib.optionalAttrs d.latest {
      hourly = 0;
      daily = 1;
    }
    // d.sanoid;
in {
  den.quirks.backup-datasets.description = "ZFS datasets this host offers to the backup hub";
  den.quirks.backup-roster.description = "Every host's backup datasets, as seen by the hub";

  # Default: every docker host offers /opt/docker when it is a ZFS dataset.
  den.aspects.docker.backup-datasets = {config, ...}:
    lib.optional (config.fileSystems ? "/opt/docker" && config.fileSystems."/opt/docker".fsType == "zfs") {
      name = "docker";
      dataset = config.fileSystems."/opt/docker".device;
    };

  # Source side, for every server: snapshots, the pull login and its
  # permissions, all from the host's own records.
  den.aspects.backup.nixos = {
    backup-datasets,
    config,
    lib,
    pkgs,
    ...
  }: let
    records = resolve backup-datasets;
    datasets = map (d: d.dataset) records;
    zfs = lib.getExe config.boot.zfs.package;
  in
    lib.mkIf (records != []) {
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
        openssh.authorizedKeys.keys = ["restrict ${hubKey}"];
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
    };

  # Hub side: one pull per dataset, pruning of the received copies, and
  # snapshots on the parent datasets so a recursive pull on the NAS sees
  # every host.
  den.policies.backup-roster = {host, ...}:
    lib.optional (host.name == hub) (
      pipe.from "backup-datasets" [
        (pipe.collectAll ({host, ...}: true))
        pipe.withProvenance
        (pipe.as "backup-roster")
      ]
    );
  den.schema.host.includes = [den.policies.backup-roster];

  den.aspects.backup.hub.nixos = {
    backup-roster,
    config,
    lib,
    pkgs,
    ...
  }: let
    hosts = lib.filter (h: h.name == hub || lib.elem h.name pulled) (lib.unique (map (r: r.source.host) backup-roster));
    jobs = lib.sort (a: b: a.unit < b.unit) (lib.concatMap (h:
      map (d:
        d
        // {
          host = h;
          unit = "${h.name}-${d.name}";
          # Datasets with history and recovery-only copies sit in separate
          # trees, so the NAS can give each tree its own retention.
          tree = "${hubPool}/${
            if d.latest
            then "latest"
            else "hosts"
          }";
        }) (resolve (map (r: r.value) (lib.filter (r: r.source.host.name == h.name) backup-roster))))
    hosts);
    remote = lib.filter (j: j.host.name != hub) jobs;
    target = j: "${j.tree}/${j.host.name}/${j.name}";
    parents = lib.unique (lib.concatMap (j: [j.tree "${j.tree}/${j.host.name}"]) jobs);
    fqdn = h: "${h.name}.${h.tailnetSuffix}";
    # Spread the pulls across the hour: after sanoid's run on the hour, and
    # re-spaced whenever a job is added or removed.
    minute = i: 5 + (i * 50) / (lib.length jobs);
  in {
    sops.secrets.backupHubSshKey.owner = "syncoid";

    programs.ssh.knownHosts = lib.listToAttrs (map (h:
      lib.nameValuePair "backup-${h.name}" {
        hostNames = ["[${fqdn h}]:${toString sshPort}"];
        publicKey = hostKeys.${h.name};
      }) (lib.unique (map (j: j.host) remote)));

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
            if j.host.name == hub
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
            ${lib.getExe config.boot.zfs.package} list -Hp -r -t filesystem,snapshot -o name,creation \
              ${lib.concatMapStringsSep " " (t: "${hubPool}/${t}") ["hosts" "latest"]} 2>/dev/null |
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
  };
}
