{
  pkgs,
  config,
  ...
}: {
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
}
