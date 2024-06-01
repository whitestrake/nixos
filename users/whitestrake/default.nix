{
  pkgs,
  inputs,
  config,
  ...
}: {
  imports = [
    inputs.home-manager.nixosModules.home-manager
    ../../secrets
  ];
  sops.secrets.whitestrakePassword.neededForUsers = true;
  users.users.whitestrake = {
    isNormalUser = true;
    hashedPasswordFile = config.sops.secrets.whitestrakePassword.path;
    extraGroups = ["wheel" "docker" "www-data" "mediaserver"];
    shell = pkgs.fish;
    openssh.authorizedKeys.keyFiles = [
      inputs.gl-keys.outPath
      inputs.gh-keys.outPath
    ];
  };
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.whitestrake = import ./home.nix;
  };
}
