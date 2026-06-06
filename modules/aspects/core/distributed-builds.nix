{...}: {
  den.aspects.distributed-builds = {
    nixos = {
      config,
      lib,
      tailnetSuffix,
      clusterHosts,
      ...
    }: let
      # den.hosts is nested as <system>.<hostname>. Flatten across systems,
      # carrying `system` into each host record so we can populate buildMachines.
      allHosts =
        lib.concatMapAttrs (
          system: hosts:
            lib.mapAttrs (_name: cfg: cfg // {inherit system;}) hosts
        )
        clusterHosts;

      thisHost = config.networking.hostName;

      # Is THIS host flagged as a builder? Drives the inline builder-user setup.
      isThisHostBuilder = allHosts.${thisHost}.builder.enable or false;

      # Shared builder defaults applied to every build machine entry.
      builderDefaults = {
        protocol = "ssh-ng";
        sshUser = "builder";
        sshKey = config.sops.secrets.nixBuilderKey.path;
        maxJobs = 4;
        supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
      };

      # Single shared SSH public key authorized for the builder user, cluster-wide.
      builderAuthorizedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJEs1Rivn0+fX55kjEuAerbgSckJyfHd0D8M+fM1dGtm nix-builder";

      # All hosts flagged as builders, EXCLUDING this host (no self-build entry).
      builderHosts =
        lib.filterAttrs
        (name: cfg: (cfg.builder.enable or false) && name != thisHost)
        allHosts;

      buildMachines =
        lib.mapAttrsToList
        (name: cfg:
          builderDefaults
          // {
            hostName = "${name}.${tailnetSuffix}";
            inherit (cfg) system;
            publicHostKey = cfg.builder.publicHostKey;
          })
        builderHosts;
    in {
      sops.secrets.nixBuilderKey = {};
      nix.distributedBuilds = true;
      nix.settings.builders-use-substitutes = true;
      nix.buildMachines = buildMachines;

      # Builder user is gated inline (was previously the separate user-builder aspect).
      # den.aspects.* cannot be imported from the nixos module layer, so we apply it
      # conditionally here based on the centralized metadata.
      users.users.builder = lib.mkIf isThisHostBuilder {
        isNormalUser = true;
        openssh.authorizedKeys.keys = [builderAuthorizedKey];
      };
      nix.settings.trusted-users = lib.mkIf isThisHostBuilder ["builder"];
    };
  };
}
