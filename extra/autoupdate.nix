{config, ...}: {
  system.autoUpgrade = {
    enable = true;
    dates = "*:20"; # Every 20 minutes
    randomizedDelaySec = "5m";

    flake = "github:whitestrake/nixos#${config.networking.hostName}";
    flags = ["--refresh"];
  };
}
