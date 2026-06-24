# Deployment Configuration (deploy-rs)
#
# Note on Deployment Coexistence:
# - deploy-rs remains supported for manual or fallback deployments.
# - Cachix Deploy is the preferred automated CI/CD activation path for hosts with registered agents.
# - Avoid running deploy-rs and Cachix Deploy concurrently against the same host.
# - As hosts move to Cachix Deploy, deploy-rs should be treated as manual fallback unless intentionally retained.
{
  self,
  inputs,
  lib,
  config,
  ...
}: {
  flake-file.inputs.deploy-rs = {
    url = "github:serokell/deploy-rs";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  flake = let
    deploy-rs = inputs.deploy-rs;

    # Flat map all host configurations defined in den.hosts
    allHosts = lib.foldl' (acc: system: acc // config.den.hosts.${system}) {} (builtins.attrNames config.den.hosts);

    # Filter out non-NixOS systems and WSL hosts (which are not deployable via deploy-rs)
    deployableNodes = let
      isWslNode = name: self.nixosConfigurations.${name}.config.wsl.enable or false;
    in
      lib.filterAttrs (name: host: host.class == "nixos" && !(isWslNode name)) allHosts;

    mkNode = name: host: {
      hostname = "${name}.${config.network.tailnetSuffix}";
      profiles.system.path = deploy-rs.lib.${host.system}.activate.nixos self.nixosConfigurations.${name};
    };

    mkDeploy = nodesList: {
      user = "root";
      sshUser = "whitestrake";
      sshOpts = ["-A"];
      nodes = lib.mapAttrs mkNode nodesList;
    };

    stripDeployPathContexts = deploy:
      deploy
      // {
        nodes = builtins.mapAttrs (
          _nodeName: node:
            node
            // {
              profiles = builtins.mapAttrs (
                _profileName: profile:
                  profile
                  // {
                    path = builtins.unsafeDiscardStringContext (toString profile.path);
                  }
              ) (node.profiles or {});
            }
        ) (deploy.nodes or {});
      };

    mkFastDeploySchemaCheck = {
      pkgs,
      deploy,
      deployRsSrc,
    }:
      pkgs.runCommand "deploy-rs-schema-fast" {
        nativeBuildInputs = [pkgs.check-jsonschema];
        deployJson = builtins.toJSON (stripDeployPathContexts deploy);
        passAsFile = ["deployJson"];
      } ''
        check-jsonschema \
          --schemafile ${deployRsSrc}/interface.json \
          "$deployJsonPath"
        touch "$out"
      '';
  in {
    # deploy-rs configurations
    deploy = mkDeploy deployableNodes;

    # Lightweight deploy-rs schema validation for CI matrix builds.
    # deploy-rs' upstream deployChecks intentionally reference full system
    # closures. That is useful for deploy-rs-only CI, but it makes these tiny
    # checks force huge host graphs in HCI, so keep the context-stripped schema
    # check here and leave full host closure verification to the real flake
    # outputs.
    checks = lib.genAttrs config.systems (
      system: let
        sysDeployableNodes = lib.filterAttrs (_: n: n.system == system) deployableNodes;
      in
        if deploy-rs.lib ? ${system} && sysDeployableNodes != {}
        then let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        in {
          deploy-schema-fast = mkFastDeploySchemaCheck {
            inherit pkgs;
            deploy = mkDeploy sysDeployableNodes;
            deployRsSrc = inputs.deploy-rs;
          };
        }
        else {}
    );
  };
}
