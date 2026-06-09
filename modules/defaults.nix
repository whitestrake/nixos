{
  den,
  inputs,
  lib,
  ...
}: {
  flake-file.inputs.sops-nix = {
    url = "github:Mic92/sops-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.schema.user.classes = lib.mkDefault ["homeManager"];

  # Base overrides applied globally to classes
  den.default = {
    includes = [
      den.provides.hostname
      den.policies.flake-root
    ];

    nixos = {
      pkgs,
      lib,
      ...
    }: {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;

      system.stateVersion = lib.mkDefault "24.05";
      nixpkgs.config.allowUnfree = true;
      time.timeZone = lib.mkDefault "Australia/Brisbane";
      networking.domain = lib.mkDefault "whitestrake.net";
      documentation.nixos.enable = false;
      imports = [inputs.sops-nix.nixosModules.sops];
      sops = {
        # Default secret file
        defaultSopsFile = ../secrets/secrets.yaml;
        # Auto import SSH host key to age
        age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
        # Default key location
        age.keyFile = "/var/lib/sops-nix/key.txt";
        # Create key if it doesn't exist
        age.generateKey = true;
      };
    };

    darwin = {
      pkgs,
      lib,
      ...
    }: {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;

      system.stateVersion = lib.mkDefault 4;
      nixpkgs.config.allowUnfree = true;
    };

    homeManager = {
      pkgs,
      lib,
      ...
    }: {
      home.stateVersion = lib.mkDefault "25.11";
      manual.html.enable = false;
      manual.manpages.enable = false;
      manual.json.enable = false;
    };
  };
}
