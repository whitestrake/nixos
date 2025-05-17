{config, ...}: {
  imports = [
    ./hardware-configuration.nix
    ../../users/whitestrake

    ../../extra/docker.nix
    ../../extra/sensu.nix
    ../../extra/alloy.nix
    ../../extra/beszel.nix
    ../../extra/komodo.nix
    ../../secrets
  ];
  system.stateVersion = "24.05";

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "jaeger";
  networking.domain = "whitestrake.net";
  time.timeZone = "Australia/Brisbane";

  # Allow for NAS pulls of the entire /opt/docker directory
  sops.secrets.hostsEnv = {};
  systemd.services.rsync.serviceConfig.EnvironmentFile = config.sops.secrets.hostsEnv.path;
  services.rsyncd.enable = true;
  services.rsyncd.settings = {
    global.address = "%HOST_JAEGER%";
    docker = {
      path = "/opt/docker";
      uid = "root";
      gid = "root";
      "hosts allow" = "%HOST_TRITON%";
      "read only" = true;
    };
  };
}
