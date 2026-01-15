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

  # Don't need Tailscale as we have it on the Windows host
  services.tailscale.enable = false;

  services.vscode-server.enable = true;
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
}
