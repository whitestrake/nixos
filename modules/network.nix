{
  config,
  lib,
  ...
}: {
  options.network.tailnetSuffix = lib.mkOption {
    type = lib.types.str;
    default = "fell-monitor.ts.net";
    description = "Tailnet DNS suffix appended to host names for tailnet-internal addressing";
  };

  config = {
    # Expose the tailnet suffix as a module argument for flake-parts modules
    # (perSystem/flake) and surface it on the flake outputs for reference.
    _module.args.tailnetSuffix = config.network.tailnetSuffix;
    flake.network.tailnetSuffix = config.network.tailnetSuffix;
  };
}
