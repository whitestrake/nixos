{
  lib,
  tailnetSuffix,
  ...
}: {
  den.aspects.distributed-builds = {
    nixos = {
      config,
      host,
      lib,
      nixBuilders,
      ...
    }: let
      thisHost = host.name;

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
        builtins.filter
        (builder: builder.name != thisHost)
        nixBuilders;

      # Is THIS host flagged as a builder? Drives the inline builder-user setup.
      isThisHostBuilder =
        builtins.any
        (builder: builder.name == thisHost)
        nixBuilders;

      buildMachines =
        map
        (builder:
          builderDefaults
          // {
            hostName = "${builder.name}.${tailnetSuffix}";
            inherit (builder) system publicHostKey;
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
