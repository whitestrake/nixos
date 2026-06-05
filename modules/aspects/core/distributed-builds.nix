{...}: {
  den.aspects.distributed-builds = {
    nixos = {
      config,
      lib,
      tailnetSuffix,
      ...
    }: {
      sops.secrets.nixBuilderKey = {};
      nix.distributedBuilds = true;
      nix.settings.builders-use-substitutes = true;
      nix.buildMachines = let
        mkMachine = attrs:
          {
            protocol = "ssh-ng";
            sshUser = "builder";
            sshKey = config.sops.secrets.nixBuilderKey.path;
            maxJobs = 4;
            supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
          }
          // attrs;
        systems = map mkMachine [
          {
            hostName = "jaeger.${tailnetSuffix}";
            system = "aarch64-linux";
            publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUdmMlhib1Q0L0N3L2JWeDdVSkZEZVdsVjNnRVJQZXhKc2hBQ0hSZTlqY3Ygcm9vdEBqYWVnZXI=";
          }
          {
            hostName = "orthus.${tailnetSuffix}";
            system = "x86_64-linux";
            publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUI0YjJjYXpXdWt0OHZyNEV0a1J4b29SQkhrYSswVXVNSTlSejlpeWt3dFcgcm9vdEBvcnRodXM=";
          }
        ];
      in
        # Don't include the current host in its own buildMachines list
        lib.filter (x: x.hostName != "${config.networking.hostName}.${tailnetSuffix}") systems;
    };
  };
}
