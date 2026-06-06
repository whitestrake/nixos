{
  den,
  inputs,
  config,
  flakeRoot,
  ...
}: let
  flakeConfig = config;
in {
  imports = [inputs.den.flakeModule];

  config = {
    # Supported systems
    systems = builtins.attrNames config.den.hosts;

    # Expose a lightweight host-to-system map for GitHub Actions
    flake.ci = builtins.mapAttrs (sys: hosts: builtins.attrNames hosts) config.den.hosts;

    den = {
      schema.host = {config, ...}: {
        instantiate = args: let
          unstable = import inputs.nixpkgs-unstable {
            inherit (config) system;
            config.allowUnfree = true;
          };
          extendedLib = inputs.nixpkgs.lib.extend (final: prev: import ../lib);
          builder =
            {
              nixos = inputs.nixpkgs.lib.nixosSystem;
              darwin = inputs.nix-darwin.lib.darwinSystem;
            }.${
              config.class
            };
        in
          builder (args
            // {
              specialArgs =
                (args.specialArgs or {})
                // {
                  inherit inputs unstable flakeRoot;
                  inherit (flakeConfig) caches;
                  inherit (flakeConfig.network) tailnetSuffix;
                  clusterHosts = flakeConfig.den.hosts;
                  lib = extendedLib;
                };
            });
      };

      schema.user = {
        classes = ["homeManager"];
      };

      # Base overrides applied globally to classes
      default = {
        includes = [
          den.provides.hostname
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

      # Declare hosts mapping and user mappings explicitly (using proper aspect references)
      hosts = {
        x86_64-linux = {
          pascal.users.whitestrake.aspect = den.aspects.user-whitestrake;
          rapier.users.whitestrake.aspect = den.aspects.user-whitestrake;
          sortie.users.whitestrake.aspect = den.aspects.user-whitestrake;
          orthus = {
            users.whitestrake.aspect = den.aspects.user-whitestrake;
            builder = {
              enable = true;
              publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUI0YjJjYXpXdWt0OHZyNEV0a1J4b29SQkhrYSswVXVNSTlSejlpeWt3dFcgcm9vdEBvcnRodXM=";
            };
          };
          oculus.users.whitestrake.aspect = den.aspects.user-whitestrake;
          omnius.users.whitestrake.aspect = den.aspects.user-whitestrake;
          kronos = {
            users.whitestrake.aspect = den.aspects.user-whitestrake;
            wsl.enable = true;
          };
        };
        aarch64-linux = {
          jaeger = {
            users.whitestrake.aspect = den.aspects.user-whitestrake;
            builder = {
              enable = true;
              publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUdmMlhib1Q0L0N3L2JWeDdVSkZEZVdsVjNnRVJQZXhKc2hBQ0hSZTlqY3Ygcm9vdEBqYWVnZXI=";
            };
          };
        };
        aarch64-darwin = {
          andred.users.whitestrake.aspect = den.aspects.user-whitestrake;
        };
      };
    };
  };
}
