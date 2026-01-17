{
  inputs,
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    inputs.attic.nixosModules.atticd
    ../secrets
    ./caddy.nix
  ];

  environment.systemPackages = [
    inputs.attic.packages.${pkgs.system}.attic-client
  ];

  # Atticd server configuration
  sops.secrets.atticEnv = {};
  services.atticd = {
    enable = true;
    environmentFile = config.sops.secrets.atticEnv.path;

    settings = {
      listen = "[::1]:8080";
      storage = {
        type = "local";
        path = "/storage/atticd";
      };
      chunking = {
        nar-size-threshold = 64 * 1024; # 64 KiB
        min-size = 16 * 1024; # 16 KiB
        avg-size = 64 * 1024; # 64 KiB
        max-size = 256 * 1024; # 256 KiB
      };
    };
  };

  # Static user/group for atticd to write to storage
  users.users.atticd.isSystemUser = true;
  users.users.atticd.group = "atticd";
  users.groups.atticd = {};
  systemd.services.atticd.serviceConfig = {
    DynamicUser = lib.mkForce false;
  };

  # Set directory ownership before service starts
  systemd.tmpfiles.rules = [
    "Z /storage/atticd 0750 atticd atticd -"
  ];

  # Reverse proxy configuration
  services.caddy.virtualHosts."attic.whitestrake.net".extraConfig = ''
    reverse_proxy localhost:8080
  '';
}
