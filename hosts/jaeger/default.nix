{
  config,
  lib,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../../users/builder.nix

    ../../extra/docker.nix
    ../../extra/sensu.nix
    ../../secrets
  ];
  system.stateVersion = "24.05";

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Set up xinetd for checkmk
  services.xinetd.enable = true;
  services.xinetd.services = [
    {
      name = "check_mk";
      port = 6556;
      protocol = "tcp";
      user = "root";
      server = "${config.services.cmk-agent.package}/bin/check_mk_agent";
      extraConfig = ''
        type = UNLISTED
        only_from = .fell-monitor.ts.net
        disable = no
      '';
    }
  ];
  # Disable the agent controller that won't work on aarch64
  systemd.services.cmk-agent-ctl-daemon.enable = lib.mkForce false;

  networking.hostName = "jaeger";
  networking.domain = "whitestrake.net";
  time.timeZone = "Australia/Brisbane";
}
