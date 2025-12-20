{
  config,
  pkgs,
  ...
}: {
  imports = [../secrets];
  sops.secrets.beszelEnv = {};

  services.beszel.agent = {
    enable = true;
    environmentFile = config.sops.secrets.beszelEnv.path;
    # package = pkgs.unstable.beszel;
    package = pkgs.beszel.overrideAttrs (oldAttrs: rec {
      version = "0.17.0";
      src = pkgs.fetchFromGitHub {
        owner = "henrygd";
        repo = "beszel";
        tag = "v${version}";
        hash = "sha256-MY/rsWdIiYsqcw6gqDkfA8A/Ied3OSHfJI3KUBxoRKc=";
      };
      vendorHash = "sha256-gfQU3jGwTGmMJIy9KTjk/Ncwpk886vMo4CJvm5Y5xpA=";
    });
  };
}
