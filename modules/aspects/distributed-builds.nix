{den, ...} @ flake: {
  den.quirks.nixBuilder.description = "Local builder declaration";
  den.quirks.nixBuilders.description = "Collected cluster-wide build machines";
  den.schema.host.includes = [flake.config.den.policies.collect-nix-builders];

  # Collects all nixBuilder declarations globally, filters out this host,
  # and routes to nixBuilders.
  den.policies.collect-nix-builders = {host, ...}: let
    inherit (den.lib.policy) pipe;
    inherit (host) name;
  in [
    (pipe.from "nixBuilder" [
      (pipe.filter (_: false))
      (pipe.collectAll ({host, ...}: host.name != name))
      pipe.withProvenance
      (pipe.as "nixBuilders")
    ])
  ];

  den.aspects.distributed-builds.nixos = {
    config,
    host,
    lib,
    pkgs,
    nixBuilder ? [],
    nixBuilders ? [],
    ...
  }:
    lib.mkMerge [
      {
        nix.distributedBuilds = true;
        nix.settings.builders-use-substitutes = true;

        # Map the collected remote builders to Nix build machine configurations.
        sops.secrets.nixBuilderKey = {};
        nix.buildMachines =
          map
          ({
            value,
            source,
          }: {
            protocol = "ssh-ng";
            sshUser = "builder";
            sshKey = config.sops.secrets.nixBuilderKey.path;
            maxJobs = 4;
            supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
            hostName = "${source.host.name}.${source.host.tailnetSuffix}";
            inherit (source.host) system;
            inherit (value) publicHostKey;
          })
          nixBuilders;
      }
      (lib.mkIf (nixBuilder != []) {
        # If this host is flagged as a builder, set up the builder user and add
        # them to trusted-users.
        users.users.builder.isSystemUser = true;
        users.users.builder.group = "nogroup";
        users.users.builder.shell = pkgs.bashInteractive;
        users.users.builder.openssh.authorizedKeys.keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJEs1Rivn0+fX55kjEuAerbgSckJyfHd0D8M+fM1dGtm nix-builder"];
        nix.settings.trusted-users = ["builder"];
      })
    ];
}
