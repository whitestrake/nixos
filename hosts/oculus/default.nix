{inputs, ...}: {
  imports = [
    "${inputs.nixpkgs}/nixos/modules/virtualisation/google-compute-image.nix"
    ../../users/whitestrake

    ../../extra/docker.nix
    ../../extra/beszel.nix
    ../../extra/check_mk.nix
    ../../secrets
  ];
  system.stateVersion = "25.05";

  # Hostname and TZ
  networking.hostName = "oculus";
  networking.domain = "whitestrake.net";
  time.timeZone = "Australia/Brisbane";

  # Workaround strange issues with metadata.google.internal routing
  networking.nameservers = ["1.1.1.1" "8.8.8.8"];
  networking.timeServers = ["pool.ntp.org"];

  swapDevices = [{device = "/swapfile";}];
}
