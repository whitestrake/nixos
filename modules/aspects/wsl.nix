{ inputs, ... }: {
  den.aspects.wsl = {
    nixos = { ... }: {
      imports = [ inputs.nixos-wsl.nixosModules.default ];
      wsl.enable = true;
      wsl.defaultUser = "whitestrake";

      # Explicit ssh-agent enablement in WSL
      users.users.whitestrake.linger = true;
      wsl.ssh-agent.enable = true;

      # Fix for running Windows binaries (Exec format error)
      environment.etc."binfmt.d/WSLInterop.conf".text = ":WSLInterop:M::MZ::/init:PF";
    };
  };
}
