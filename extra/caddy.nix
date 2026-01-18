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
    package = pkgs.myPkgs.caddy;
    globalConfig = ''
      acme_dns cloudflare {env.CF_API_TOKEN}
      email {env.ACME_EMAIL}
    '';
  };

  networking.firewall.allowedTCPPorts = [80 443];
}
