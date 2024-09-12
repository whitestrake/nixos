{
  inputs,
  pkgs,
  ...
}: {
  imports = [
    inputs.nixos-wsl.nixosModules.wsl
    inputs.vscode-server.nixosModules.default
    ../../users/whitestrake
  ];

  wsl.enable = true;
  wsl.defaultUser = "whitestrake";
  system.stateVersion = "23.11";

  networking.hostName = "charon";
  networking.domain = "whitestrake.net";
  time.timeZone = "Australia/Brisbane";

  services.vscode-server.enable = true;
  environment.systemPackages = with pkgs; [
    sops
    age
    deploy-rs
    nil
    alejandra
  ];
}
