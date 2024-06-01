{inputs, ...}: {
  imports = [inputs.nixos-wsl.nixosModules.wsl];

  wsl.enable = true;
  wsl.defaultUser = "whitestrake";
  system.stateVersion = "23.11";

  networking.hostName = "charon";
  networking.domain = "whitestrake.net";
  time.timeZone = "Australia/Brisbane";
}
