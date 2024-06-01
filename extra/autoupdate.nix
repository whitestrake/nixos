{
  system.autoUpgrade = {
    enable = true;
    dates = "02:00";
    randomizedDelaySec = "1h";
    allowReboot = true;

    flake = "github:whitestrake/nixos";
    flags = ["--refresh"];
  };

  nix.gc = {
    automatic = true;
    dates = "03:00";
    options = "--delete-older-than 7d";
  };
}
