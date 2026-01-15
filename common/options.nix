{lib, ...}: {
  options.host.isServer = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether the host is a server.";
  };
}
