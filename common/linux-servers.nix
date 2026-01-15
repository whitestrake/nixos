{
  config,
  pkgs,
  ...
}: {
  imports = [
    ../extra/beszel.nix
    ../extra/alloy.nix
    ../secrets
  ];

  # Allow server hosts to auto register themselves with server tag
  sops.secrets.tailscaleOauthKey = {};
  services.tailscale = {
    authKeyFile = config.sops.secrets.tailscaleOauthKey.path;
    useRoutingFeatures = "both";
  };

  # Make tailscaled wait until it has an IP before telling systemd it's ready
  # Allows services like rsyncd to wait until after tailscaled.service
  # https://github.com/tailscale/tailscale/issues/11504
  systemd.services.tailscaled.serviceConfig.ExecStartPost = ''
    ${pkgs.coreutils}/bin/timeout 60s ${pkgs.bash}/bin/bash -c 'until ${config.services.tailscale.package}/bin/tailscale status --peers=false; do sleep 1; done'
  '';
}
