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
  sops.secrets = {
    atticEnv = {};
    caddyEnv = {};
  };

  environment.systemPackages = [
    inputs.attic.packages.${pkgs.system}.attic-client
  ];

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

  # Reverse proxy configuration
  services.caddy = {
    enable = true;
    environmentFile = config.sops.secrets.caddyEnv.path;
    package = pkgs.unstable.caddy.withPlugins {
      plugins = [
        "github.com/caddy-dns/cloudflare@latest"
      ];
    };
    globalConfig = ''
      acme_dns cloudflare {env.CF_API_TOKEN}
      email {env.ACME_EMAIL}
    '';
    virtualHosts = {
      "attic.whitestrake.net" = {
        extraConfig = ''
          reverse_proxy localhost:8080
        '';
      };
    };
  };
  networking.firewall.allowedTCPPorts = [80 443];
}
