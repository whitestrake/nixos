{ self, inputs, lib, ... }: {
  flake = let
    deploy-rs = inputs.deploy-rs;

    nodes = {
      pascal = { system = "x86_64-linux"; };
      rapier = { system = "x86_64-linux"; };
      sortie = { system = "x86_64-linux"; };
      orthus = { system = "x86_64-linux"; };
      oculus = { system = "x86_64-linux"; };
      omnius = { system = "x86_64-linux"; };
      jaeger = { system = "aarch64-linux"; };
      kronos = { system = "x86_64-linux"; deployable = false; };
    };

    deployableNodes = lib.filterAttrs (_: n: n.deployable or true) nodes;

    mkNode = name: meta: {
      hostname = "${name}.fell-monitor.ts.net";
      profiles.system.path = deploy-rs.lib.${meta.system}.activate.nixos self.nixosConfigurations.${name};
    } // (meta.deploy or {});

    mkDeploy = nodesList: {
      user = "root";
      sshUser = "whitestrake";
      sshOpts = ["-A"];
      nodes = lib.mapAttrs mkNode nodesList;
    };
  in {
    # deploy-rs configurations
    deploy = mkDeploy deployableNodes;

    # checks for CI matrix builds
    checks = lib.genAttrs [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      if deploy-rs.lib ? ${system}
      then deploy-rs.lib.${system}.deployChecks (mkDeploy (lib.filterAttrs (_: n: n.system == system) deployableNodes))
      else {}
    );
  };
}
