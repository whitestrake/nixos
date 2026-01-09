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

  # Fix for running Windows binaries (Exec format error)
  environment.etc."binfmt.d/WSLInterop.conf".text = ":WSLInterop:M::MZ::/init:PF";

  services.vscode-server.enable = true;

  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    age
    sops
    deploy-rs
    (writeShellScriptBin "deploy-rs-async" ''
      ${inputs.deploy-rs-async.packages.${stdenv.hostPlatform.system}.deploy-rs}/bin/deploy --remote-build
    '')
    alejandra
    nil
  ];

  networking.hostName = "kronos";
  networking.domain = "whitestrake.net";
  time.timeZone = "Australia/Brisbane";

  system.stateVersion = "25.11";
}
