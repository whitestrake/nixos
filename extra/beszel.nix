{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: {
  imports = [
    # Use beszel-agent module from unstable (systemd monitoring support)
    "${inputs.nixpkgs-unstable}/nixos/modules/services/monitoring/beszel-agent.nix"
  ];

  # Disable the base nixpkgs beszel-agent module to avoid conflicts
  disabledModules = ["services/monitoring/beszel-agent.nix"];

  sops.secrets.beszelEnv = {};
  services.beszel.agent = {
    enable = lib.mkDefault true;
    package = pkgs.myPkgs.beszel;
    environmentFile = config.sops.secrets.beszelEnv.path;
    environment.SYSTEM_NAME = lib.mkDefault (lib.strings.toSentenceCase config.networking.hostName);
  };
}
