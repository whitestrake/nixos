{
  config,
  inputs,
  pkgs,
  lib,
  ...
}: {
  imports = [
    inputs.vscode-server.nixosModules.default
    ./hardware-configuration.nix
    ../../users/whitestrake

    ../../extra/docker.nix
    ../../extra/sensu.nix
    ../../extra/alloy.nix
    ../../extra/beszel.nix
    ../../extra/komodo.nix
    ../../secrets
  ];
  system.stateVersion = "23.11";

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/vda";
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  networking.hostName = "ishtar";
  networking.domain = "whitestrake.net";
  networking.networkmanager.enable = true;
  time.timeZone = "Australia/Brisbane";

  # https://github.com/NixOS/nixpkgs/issues/180175#issuecomment-1502421373
  systemd.services.NetworkManager-wait-online.enable = lib.mkForce false;
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;

  services.qemuGuest.enable = true;

  services.vscode-server.enable = true;
  environment.systemPackages = with pkgs; [
    sops
    age
    deploy-rs
    nil
    alejandra
  ];

  sops.secrets."backupTeamspeak/filePath" = {};
  sops.secrets."backupTeamspeak/pingUrl" = {};
  systemd.services.backup-teamspeak.path = with pkgs; [util-linux duplicacy curl];
  systemd.services.backup-teamspeak.script = ''
    {
      flock -nx 9 || exit 0
      cd $(cat ${config.sops.secrets."backupTeamspeak/filePath".path}) || exit 1
      result=$(mktemp) && trap 'rm "$result"' EXIT
      url=$(cat ${config.sops.secrets."backupTeamspeak/pingUrl".path})
      {
        duplicacy backup -stats
        duplicacy prune -exclusive \
          -keep 365:365 \
          -keep 30:30 \
          -keep 7:7 \
          -all
      } 2>&1 | tee "$result"
      curl --max-time 10 --retry 5 --data-binary "@$result" "$url/''${PIPESTATUS[0]}"
    } 9>/tmp/backup-teamspeak.lock
  '';
  systemd.timers.backup-teamspeak = {
    wantedBy = ["timers.target"];
    timerConfig.Unit = "backup-teamspeak.service";
    timerConfig.OnCalendar = "daily";
  };
}
