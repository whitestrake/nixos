{
  config,
  lib,
  ...
}: {
  imports = [../secrets];
  sops.secrets.alloyEnv = {};

  services.alloy.enable = lib.mkDefault true;
  services.alloy.extraFlags = ["--stability.level=public-preview"];
  systemd.services.alloy = {
    environment.GCLOUD_FM_COLLECTOR_ID = config.networking.hostName;
    serviceConfig =
      {
        EnvironmentFile = config.sops.secrets.alloyEnv.path;
      }
      // lib.optionalAttrs config.virtualisation.docker.enable {
        # Root required for Alloy to run standalone cAdvisor
        User = "root";
        SupplementaryGroups = ["docker"];
      };
  };

  environment.etc."alloy/config.alloy".text = ''
    remotecfg {
      url            = sys.env("GCLOUD_FM_URL")
      id             = sys.env("GCLOUD_FM_COLLECTOR_ID")
      poll_frequency = sys.env("GCLOUD_FM_POLL_FREQUENCY")

      basic_auth {
        username = sys.env("GCLOUD_FM_HOSTED_ID")
        password = sys.env("GCLOUD_RW_API_KEY")
      }
    }
  '';
}
