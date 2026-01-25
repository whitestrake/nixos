{
  lib,
  pkgs,
  config,
  ...
}: {
  systemd.services.netronome = {
    description = "Netronome Agent - Network Speed Testing and Monitoring";
    documentation = ["https://github.com/autobrr/netronome"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];

    path = with pkgs; [
      iperf3
      librespeed-cli
      traceroute
      mtr
      vnstat
    ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.myPkgs.netronome}/bin/netronome agent --tailscale";
      Restart = "always";
      RestartSec = 10;

      # Security hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };
}
