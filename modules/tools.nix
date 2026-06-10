{den, ...}: let
  baseSystemPackages = pkgs:
    with pkgs; [
      fish
      helix
      nh

      # File system tools
      dua
      tree
      rclone

      # Search tools
      fd
      ripgrep

      # Data inspection
      jq
      fx

      # Network clients
      wget
      curl
      xh

      # Troubleshooting
      btop
      mtr
      tcpdump
      dig
      whois
      rdap
      iperf
    ];
in {
  den.default = {
    nixos = {pkgs, ...}: {
      environment.systemPackages = baseSystemPackages pkgs;
    };

    darwin = {pkgs, ...}: {
      environment.systemPackages = baseSystemPackages pkgs;
    };
  };
}
