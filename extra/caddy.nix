{
  config,
  pkgs,
  ...
}: {
  imports = [../secrets];
  sops.secrets.caddyEnv = {};

  services.caddy = {
    enable = true;
    environmentFile = config.sops.secrets.caddyEnv.path;
    package = pkgs.unstable.caddy.withPlugins {
      plugins = ["github.com/caddy-dns/cloudflare@v0.2.2"];
      hash = "sha256-dnhEjopeA0UiI+XVYHYpsjcEI6Y1Hacbi28hVKYQURg=";
    };
    globalConfig = ''
      acme_dns cloudflare {env.CF_API_TOKEN}
      email {env.ACME_EMAIL}
    '';
  };

  networking.firewall.allowedTCPPorts = [80 443];
}
