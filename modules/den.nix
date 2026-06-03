{ den, inputs, lib, config, ... }: {
  imports = [ inputs.den.flakeModule ];

  config = {
    # Supported systems
    systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];

    den = {
      schema.host = { config, ... }: {
        instantiate = args:
          let
            unstable = import inputs.nixpkgs-unstable {
              inherit (config) system;
              config.allowUnfree = true;
            };
            extendedLib = inputs.nixpkgs.lib.extend (final: prev: import ../lib);
            builder = {
              nixos = inputs.nixpkgs.lib.nixosSystem;
              darwin = inputs.nix-darwin.lib.darwinSystem;
            }.${config.class};
          in
          builder (args // {
            specialArgs = (args.specialArgs or {}) // {
              inherit inputs unstable;
              lib = extendedLib;
            };
          });
      };

      schema.user = {
        classes = [ "homeManager" ];
      };

      # Base overrides applied globally to classes
      default = {
        nixos = { pkgs, lib, ... }: {
          system.stateVersion = lib.mkDefault "24.05";
          nixpkgs.config.allowUnfree = true;
          documentation.nixos.enable = false;
          imports = [ inputs.sops-nix.nixosModules.sops ];
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
        darwin = { pkgs, lib, ... }: {
          system.stateVersion = lib.mkDefault 4;
          nixpkgs.config.allowUnfree = true;
        };
        homeManager = { pkgs, lib, ... }: {
          home.stateVersion = lib.mkDefault "25.11";
          nixpkgs.config.allowUnfree = true;
          manual.html.enable = false;
          manual.manpages.enable = false;
          manual.json.enable = false;
        };
      };

      # Declare hosts mapping and user mappings explicitly (using proper aspect references)
      hosts = {
        x86_64-linux = {
          pascal.users.whitestrake.aspect = den.aspects.user-whitestrake;
          rapier.users.whitestrake.aspect = den.aspects.user-whitestrake;
          sortie.users.whitestrake.aspect = den.aspects.user-whitestrake;
          orthus.users.whitestrake.aspect = den.aspects.user-whitestrake;
          oculus.users.whitestrake.aspect = den.aspects.user-whitestrake;
          omnius.users.whitestrake.aspect = den.aspects.user-whitestrake;
          kronos.users.whitestrake.aspect = den.aspects.user-whitestrake;
        };
        aarch64-linux = {
          jaeger.users.whitestrake.aspect = den.aspects.user-whitestrake;
        };
        aarch64-darwin = {
          andred.users.whitestrake.aspect = den.aspects.user-whitestrake;
        };
      };
    };
  };
}
