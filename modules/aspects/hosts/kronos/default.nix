{den, ...}: {
  den.aspects.kronos = {
    includes = [
      den.aspects.common-base
      den.aspects.vscode-server
    ];

    nixos = {pkgs, ...}: {
      # Explicit ssh-agent enablement in WSL
      users.users.whitestrake.linger = true;
      wsl.ssh-agent.enable = true;

      # Fix for running Windows binaries (Exec format error)
      environment.etc."binfmt.d/WSLInterop.conf".text = ":WSLInterop:M::MZ::/init:PF";

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

      networking.domain = "whitestrake.net";
      time.timeZone = "Australia/Brisbane";

      system.stateVersion = "25.11";
    };
  };
}
