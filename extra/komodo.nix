{
  pkgs,
  config,
  ...
}: let
  komodo-next = pkgs.unstable.komodo.overrideAttrs (oldAttrs: rec {
    version = "1.17.4";
    src = pkgs.fetchFromGitHub {
      owner = "moghtech";
      repo = "komodo";
      tag = "v${version}";
      hash = "sha256-HV+32Mv9nuAG2jfM3tadMX17wQNt6FeZOsHyiJ7nCDs=";
    };
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      inherit src;
      hash = "sha256-IC+mPxoSv6kKKkiJw3UpcTTDlrlhnNpCNyW9XPlrMgA=";
    };
  });
in {
  imports = [../secrets];
  sops.secrets.komodoEnv = {};

  systemd.services.komodo-periphery = {
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];
    description = "Agent to connect with Komodo Core";
    path = with pkgs; [bash docker];
    serviceConfig = {
      EnvironmentFile = config.sops.secrets.komodoEnv.path;
      ExecStart = "${komodo-next}/bin/periphery";
      Restart = "always";
    };
  };
}
