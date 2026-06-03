{ config, pkgs, ... }: {
  den.aspects.docker = {
    nixos = { config, pkgs, ... }: {
      # Docker Service
      virtualisation.docker.enable = true;
      virtualisation.docker.autoPrune.enable = true;
      virtualisation.docker.liveRestore = false;
      systemd.tmpfiles.rules = ["d /opt/docker 0770 nobody docker"];

      environment.shellAliases = {
        dps = "docker ps -as --format 'table {{.Names}}\t{{.Status}}\t{{.Size}}'";
        dc = "docker compose";
        dcl = "dc logs -f --tail 20";
      };

      # Allow for NAS pulls of the entire /opt/docker directory via rsyncd
      services.rsyncd.enable = true;
      services.rsyncd.settings = {
        globalSection.address = "${config.networking.hostName}.fell-monitor.ts.net";
        sections = {
          docker = {
            path = "/opt/docker";
            uid = "root";
            gid = "root";
            "hosts allow" = "triton.fell-monitor.ts.net,tempus.fell-monitor.ts.net";
            "read only" = true;
          };
        };
      };
      systemd.services.rsync.requires = ["tailscaled.service"];
      systemd.services.rsync.after = ["tailscaled.service"];

      # Komodo Periphery Agent
      sops.secrets.komodoOnboardingKey = {};
      sops.templates."komodo-periphery.env" = {
        content = ''
          PERIPHERY_ROOT_DIRECTORY=/opt/docker
          PERIPHERY_REPO_DIR=/opt/docker/komodo/repos
          PERIPHERY_STACK_DIR=/opt/docker/komodo/stacks
          PERIPHERY_CORE_ADDRESS=https://komodo.whitestrake.net
          PERIPHERY_CONNECT_AS=${config.networking.hostName}
          PERIPHERY_ONBOARDING_KEY=${config.sops.placeholder.komodoOnboardingKey}
          PERIPHERY_INCLUDE_DISK_MOUNTS=/etc/hostname
        '';
      };

      systemd.services.komodo-periphery = {
        after = ["network-online.target"];
        wants = ["network-online.target"];
        wantedBy = ["multi-user.target"];
        description = "Agent to connect with Komodo Core";
        path = with pkgs; [bash docker openssl];
        serviceConfig = {
          EnvironmentFile = config.sops.templates."komodo-periphery.env".path;
          ExecStart = "${pkgs.myPkgs.komodo}/bin/periphery";
          Restart = "always";
          RestartSec = "5s";
        };
      };
    };
  };
}
