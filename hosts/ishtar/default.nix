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
    ../../extra/alloy.nix
    ../../extra/beszel.nix
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

  services.tailscale.enable = true; # Tailscale networking
  services.tailscale.package = pkgs.unstable.tailscale;

  # Allow for NAS pulls of the entire /opt/docker directory
  sops.secrets.hostsEnv = {};
  systemd.services.rsync.serviceConfig.EnvironmentFile = config.sops.secrets.hostsEnv.path;
  services.rsyncd.enable = true;
  services.rsyncd.settings = {
    global.address = "%HOST_ISHTAR%";
    docker = {
      path = "/opt/docker";
      uid = "root";
      gid = "root";
      "hosts allow" = "%HOST_TRITON%";
      "read only" = true;
    };
  };

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
