{
  inputs,
  config,
  ...
}: let
  flakeConfig = config;
in {
  imports = [
    inputs.den.flakeModule
    (inputs.den.namespace "whitestrake" true)
  ];

  # Temporary bridge. Later tasks remove every value from this override, then
  # delete the override entirely so Den's built-in host instantiation is used.
  den.schema.host = {config, ...}: {
    instantiate = args: let
      builder =
        {
          nixos = inputs.nixpkgs.lib.nixosSystem;
          darwin = inputs.darwin.lib.darwinSystem;
        }.${
          config.class
        };
    in
      builder (args
        // {
          specialArgs =
            (args.specialArgs or {})
            // {
              clusterHosts = flakeConfig.den.hosts;
            };
        });
  };
}
