{
  config,
  pkgs,
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
  system.stateVersion = "22.05"; # System state compatibility

  # Use the systemd-boot EFI boot loader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernel.sysctl = {
    "kern.ipc.maxsockbuf" = 3014656;
    "net.core.rmem_max" = 2500000;
    "vm.swappiness" = 10;
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # Hostname and TZ
  networking.hostName = "omnius";
  networking.domain = "whitestrake.net";
  time.timeZone = "Australia/Brisbane";

  # systemd configuration
  systemd.extraConfig = ''
    DefaultTimeoutStopSec=10s
  '';

  # Services
  services.rpcbind.enable = true;
  services.xe-guest-utilities.enable = true; # Xen server guest utilities

  services.tailscale.enable = true; # Tailscale networking
  services.tailscale.package = pkgs.unstable.tailscale;

  networking.firewall = {
    allowedTCPPorts = [
      # Plex
      32400
    ];
    allowedUDPPorts = [
      # Plex
      32410
      32412
      32413
      32414
    ];
  };

  # www-data user
  users.users.www-data.isSystemUser = true;
  users.users.www-data.group = "www-data";
  users.users.www-data.uid = 33;
  users.groups.www-data.gid = 33;

  # mediaserver user
  users.users.mediaserver.isSystemUser = true;
  users.users.mediaserver.group = "mediaserver";
  users.users.mediaserver.uid = 1001;
  users.groups.mediaserver.gid = 1001;

  sops.secrets."smbCredentials/omnius@corpus" = {};
  fileSystems = let
    corpus = {
      fsType = "cifs";
      noCheck = true;
      options = [
        "soft"
        "nofail"
        "_netdev"
        "x-systemd.automount"
        "x-systemd.idle-timeout=60"
        "x-systemd.mount-timeout=5"
        "x-systemd.device-timeout=5"
        "file_mode=0660"
        "dir_mode=0770"
        "credentials=${config.sops.secrets."smbCredentials/omnius@corpus".path}"
      ];
    };
  in {
    "/mnt/plex" =
      corpus
      // {
        device = "//10.0.0.122/Plex";
        options = corpus.options ++ ["uid=1001" "gid=1001"];
      };
    "/mnt/media" =
      corpus
      // {
        device = "//10.0.0.122/Media";
        options = corpus.options ++ ["uid=1001" "gid=1001"];
      };
    "/mnt/nextcloud" =
      corpus
      // {
        device = "//10.0.0.122/Nextcloud";
        options = corpus.options ++ ["uid=33" "gid=33"];
      };
    "/mnt/downloads" = {
      device = "/dev/disk/by-label/downloads";
      fsType = "xfs";
    };
  };

  # Keep the PhotoTranscoder folder clean for Plex
  systemd.services.cleanup-phototranscoder.path = with pkgs; [findutils];
  systemd.services.cleanup-phototranscoder.script = ''
    find '/opt/docker/mediaserver/plex/Library/Application Support/Plex Media Server/Cache/PhotoTranscoder' \
      -name "*.jpg" -type f -atime +5 -delete -print
  '';
  systemd.timers.cleanup-phototranscoder = {
    wantedBy = ["timers.target"];
    timerConfig.Unit = "cleanup-phototranscoder.service";
    timerConfig.OnCalendar = "*-*-* 00/6:00:00";
  };

  # Allow for NAS pulls of the entire /opt/docker directory
  sops.secrets.hostsEnv = {};
  systemd.services.rsync.serviceConfig.EnvironmentFile = config.sops.secrets.hostsEnv.path;
  services.rsyncd.enable = true;
  services.rsyncd.settings = {
    global.address = "%HOST_OMNIUS%";
    docker = {
      path = "/opt/docker";
      uid = "root";
      gid = "root";
      "hosts allow" = "%HOST_TRITON%";
      "read only" = true;
    };
  };
}
