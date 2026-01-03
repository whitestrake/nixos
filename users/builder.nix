{...}: {
  users.users.builder = {
    isNormalUser = true;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJEs1Rivn0+fX55kjEuAerbgSckJyfHd0D8M+fM1dGtm nix-builder"
    ];
  };
  nix.settings.trusted-users = ["builder"];
}
