{
  inputs,
  pkgs,
  ...
}: {
  imports = [
    inputs.nixos-wsl.nixosModules.default
    inputs.vscode-server.nixosModules.default
  ];

  wsl.enable = true;
  wsl.defaultUser = "whitestrake";

  # Explicit ssh-agent enablement in WSL
  users.users.whitestrake.linger = true;
  programs.ssh.startAgent = true;

  # Fix for running Windows binaries (Exec format error)
  environment.etc."binfmt.d/WSLInterop.conf".text = ":WSLInterop:M::MZ::/init:PF";

  # Turn off some server-specific monitoring/networking that aren't needed in WSL
  services.alloy.enable = false;
  services.beszel.agent.enable = false;
  services.tailscale.enable = false;

  services.vscode-server.enable = true;
  environment.systemPackages = with pkgs; [
    age
    sops
    deploy-rs
    alejandra
    nil
    nix-update
  ];
  environment.shellAliases.deploy-rs-async = let
    system = pkgs.stdenv.hostPlatform.system;
    deploy-rs-async = inputs.deploy-rs-async.packages.${system}.deploy-rs;
  in "${deploy-rs-async}/bin/deploy --remote-build";

  networking.hostName = "kronos";
  networking.domain = "whitestrake.net";
  time.timeZone = "Australia/Brisbane";

  system.stateVersion = "25.11";
}
