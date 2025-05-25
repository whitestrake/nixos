{
  pkgs,
  config,
  ...
}: {
  # }: let
  #   komodo-next = pkgs.unstable.komodo.overrideAttrs (oldAttrs: rec {
  #     version = "1.17.5";
  #     src = pkgs.fetchFromGitHub {
  #       owner = "moghtech";
  #       repo = "komodo";
  #       tag = "v${version}";
  #       hash = "sha256-vIK/4WH85qTdjXBX32F6P/XEHdsNw2Kd86btjfl13lE=";
  #     };
  #     cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
  #       inherit src;
  #       hash = "sha256-YCSxMcuzN1IroDfbj18yjGT0ua1xfY4l0dJ/OZhHPZw=";
  #     };
  #   });
  # in {
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
      ExecStart = "${pkgs.unstable.komodo}/bin/periphery";
      Restart = "always";
    };
  };
}
