{inputs, ...}: {
  imports = [
    "${inputs.nixpkgs}/nixos/modules/virtualisation/google-compute-image.nix"
    ../../users/whitestrake

    ../../extra/docker.nix
    ../../extra/beszel.nix
    ../../secrets
  ];
  system.stateVersion = "25.05";

  # Hostname and TZ
  networking.hostName = "oculus";
  networking.domain = "whitestrake.net";
  time.timeZone = "Australia/Brisbane";

  # GCE nameserver from DHCP seems flaky? Their problem or ours? Temp workaround
  networking.nameservers = ["1.1.1.1" "8.8.8.8"];
}
