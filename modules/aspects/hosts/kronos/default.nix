{ den, ... }: {
  den.aspects.kronos = {
    includes = [
      den.provides.hostname
      den.aspects.common-base
      den.aspects.wsl
      den.aspects.vscode-server
    ];

    nixos = { pkgs, ... }: {
      # Don't need Tailscale as we have it on the Windows host
      services.tailscale.enable = false;

      # Use systemd-resolved for native, robust mDNS resolution
      services.resolved = {
        enable = true;
        llmnr = "false";
        extraConfig = ''
          MulticastDNS=resolve
        '';
      };

      environment.systemPackages = with pkgs; [
        age
        sops
        deploy-rs
        alejandra
        nil
        nix-update
        nix-inspect
      ];

      networking.hostName = "kronos";
      networking.domain = "whitestrake.net";
      time.timeZone = "Australia/Brisbane";

      system.stateVersion = "25.11";
    };
  };
}
