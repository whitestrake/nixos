{
  inputs,
  config,
  lib,
  pkgs,
  ...
}: {
  nixpkgs.overlays = [
    (final: prev: {
      checkmk-agent = final.callPackage "${inputs.check_mk-pr}/pkgs/by-name/ch/checkmk-agent/package.nix" {};
    })
  ];
  imports = ["${inputs.check_mk-pr}/nixos/modules/services/monitoring/cmk-agent.nix"];
  services.cmk-agent.enable = true;
  environment.systemPackages = [config.services.cmk-agent.package];

  # Set up xinetd for checkmk on aarch64
  # The agent controller doesn't work on aarch64, so we need to use xinetd
  services.xinetd.enable = lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 true;
  services.xinetd.services = lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 [
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
  systemd.services.cmk-agent-ctl-daemon.enable = lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 (lib.mkForce false);
}
