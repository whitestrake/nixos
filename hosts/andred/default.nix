{
  pkgs,
  inputs,
  ...
}: {
  imports = [inputs.home-manager.darwinModules.home-manager];

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;
  system.primaryUser = "whitestrake";

  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    age
    sops
    deploy-rs
    alejandra
    nixos-rebuild
    nil
  ];
  environment.shellAliases.deploy-rs-async = let
    system = pkgs.stdenv.hostPlatform.system;
    deploy-rs-async = inputs.deploy-rs-async.packages.${system}.deploy-rs;
  in "${deploy-rs-async}/bin/deploy --remote-build";

  # User configuration
  programs.fish.enable = true;
  programs.zsh.enable = true;
  users.users.whitestrake.shell = pkgs.fish;
  users.users.whitestrake.home = "/Users/whitestrake";
  home-manager.users.whitestrake = {lib, ...}: {
    imports = [../../users/whitestrake/home.nix];
    home.sessionVariables.EDITOR = "code"; # VS Code
    home.sessionVariables.CLICOLOR = "1"; # Enable colours in terminal outputs
    home.shellAliases.tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
  };
}
