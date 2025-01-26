{
  config,
  pkgs,
  lib,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../../users/whitestrake

    ../../extra/docker.nix
    ../../extra/sensu.nix
    ../../extra/netdata.nix
    ../../secrets
  ];
  system.stateVersion = "24.11";

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/vda";
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  networking.hostName = "orthus";
  networking.domain = "whitestrake.net";
  time.timeZone = "Australia/Brisbane";

  # https://github.com/NixOS/nixpkgs/issues/180175#issuecomment-1502421373
  systemd.services.NetworkManager-wait-online.enable = lib.mkForce false;
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;

  services.tailscale.enable = true; # Tailscale networking
  services.tailscale.package = pkgs.unstable.tailscale;

  # Allow for NAS pulls of the entire /opt/docker directory
  sops.secrets.hostsEnv = {};
  systemd.services.rsync.serviceConfig.EnvironmentFile = config.sops.secrets.hostsEnv.path;
  services.rsyncd.enable = true;
  services.rsyncd.settings = {
    global.address = "%HOST_ORTHUS%";
    docker = {
      path = "/opt/docker";
      uid = "root";
      gid = "root";
      "hosts allow" = "%HOST_TRITON%";
      "read only" = true;
    };
  };
}
