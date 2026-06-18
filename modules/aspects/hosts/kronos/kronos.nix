{den, ...}: {
  den.aspects.kronos = {
    includes = [
      den.aspects.vscode-server
      den.aspects.dev-tools
    ];

    nixos = {pkgs, ...}: {
      # Explicit ssh-agent enablement in WSL
      users.users.whitestrake.linger = true;
      wsl.ssh-agent.enable = true;

      # Fix for running Windows binaries (Exec format error)
      environment.etc."binfmt.d/WSLInterop.conf".text = ":WSLInterop:M::MZ::/init:PF";

      # Use systemd-resolved for native, robust mDNS resolution
      services.resolved = {
        enable = true;
        settings.Resolve = {
          LLMNR = "false";
          MulticastDNS = "resolve";
        };
      };

      # Enable envfs to automatically populate /bin and /usr/bin with binaries from PATH
      # This fixes issues with VS Code Server extensions, Codex, and other FHS-assuming tools
      services.envfs.enable = true;

      system.stateVersion = "25.11";
    };
  };
}
