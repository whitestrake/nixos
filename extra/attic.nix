{
  inputs,
  config,
  pkgs,
  ...
}: {
  imports = [
    inputs.attic.nixosModules.atticd
    ../secrets
  ];
  sops.secrets.atticEnv = {};

  # Atticd server configuration
  services.atticd = {
    enable = true;
    environmentFile = config.sops.secrets.atticEnv.path;

    settings = {
      listen = "[::1]:8080";
      chunking = {
        nar-size-threshold = 64 * 1024; # 64 KiB
        min-size = 16 * 1024; # 16 KiB
        avg-size = 64 * 1024; # 64 KiB
        max-size = 256 * 1024; # 256 KiB
      };
    };
  };
}
