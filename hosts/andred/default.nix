{
  pkgs,
  inputs,
  ...
}: {
  imports = [inputs.home-manager.darwinModules.home-manager];

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;

  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    age
    sops
    deploy-rs
    alejandra
    nixos-rebuild
    nil
  ];

  # User configuration
  programs.fish.enable = true;
  programs.zsh.enable = true;
  users.users.whitestrake.shell = pkgs.fish;
  users.users.whitestrake.home = "/Users/whitestrake";
  home-manager.users.whitestrake = {lib, ...}: {
    imports = [../../users/whitestrake/home.nix];
    home.sessionVariables.EDITOR = lib.mkForce "code"; # VS Code
    home.sessionVariables.CLICOLOR = lib.mkForce "1"; # Enable colours in terminal outputs
    home.shellAliases.tailscale = lib.mkForce "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
    programs.fish.interactiveShellInit = lib.mkForce ''
      set fish_greeting
      thefuck --alias | source
      fish_add_path $GOPATH/bin/
    '';
  };
}
