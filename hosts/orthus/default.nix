{lib, ...}: {
  imports = [
    ./hardware-configuration.nix
    ../../users/builder.nix
    ../../extra/docker.nix
    ../../extra/sensu.nix
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

  networking.firewall.trustedInterfaces = [
    "beszel0" # Beszel container to agent communication
    "komodo0" # Komodo container to agent communication
    "checkmk0" # Checkmk container to agent communication
  ];
}
