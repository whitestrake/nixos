{
  lib,
  pkgs,
  config,
  ...
}: {
  imports = [../secrets];
  sops.secrets.netronomeEnv = {};

  systemd.services.netronome = {
    description = "Netronome Agent - Network Speed Testing and Monitoring";
    documentation = ["https://github.com/autobrr/netronome"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];

    environment = {
      NETRONOME__AGENT_HOST = lib.mkDefault "0.0.0.0";
      NETRONOME__AGENT_PORT = lib.mkDefault "8200";
      NETRONOME__AGENT_INTERFACE = lib.mkDefault "";
      NETRONOME__AGENT_DISK_INCLUDES = lib.mkDefault "";
      NETRONOME__AGENT_DISK_EXCLUDES = lib.mkDefault "";
    };

    path = with pkgs; [
      iperf3
      librespeed-cli
      traceroute
      mtr
      vnstat
    ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.myPkgs.netronome}/bin/netronome agent";
      Restart = "always";
      RestartSec = 10;
      EnvironmentFile = config.sops.secrets.netronomeEnv.path;

      # Security hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };
}
