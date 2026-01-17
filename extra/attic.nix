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

  # Atticd server configuration
  services.atticd = {
    enable = true;

    # Credentials file with ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64
    sops.secrets.atticEnv = {};
    environmentFile = config.sops.secrets.atticEnv.path;

    settings = {
      listen = "[::1]:8080";

      database.url = "sqlite:///storage/atticd/server.db?mode=rwc";

      storage = {
        type = "local";
        path = "/storage/atticd/data";
      };

      chunking = {
        nar-size-threshold = 64 * 1024; # 64 KiB
        min-size = 16 * 1024; # 16 KiB
        avg-size = 64 * 1024; # 64 KiB
        max-size = 256 * 1024; # 256 KiB
      };
    };
  };
}
