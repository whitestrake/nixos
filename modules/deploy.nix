{
  self,
  inputs,
  lib,
  config,
  ...
}: {
  flake = let
    deploy-rs = inputs.deploy-rs;

    # Flat map all host configurations defined in den.hosts
    allHosts = lib.foldl' (acc: system: acc // config.den.hosts.${system}) {} (builtins.attrNames config.den.hosts);

    # Filter out non-NixOS systems and WSL hosts (which are not deployable via deploy-rs)
    deployableNodes = lib.filterAttrs (name: host: host.class == "nixos" && !(host.wsl.enable or false)) allHosts;

    mkNode = name: host: {
      hostname = "${name}.fell-monitor.ts.net";
      profiles.system.path = deploy-rs.lib.${host.system}.activate.nixos self.nixosConfigurations.${name};
    };

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
    checks = lib.genAttrs ["x86_64-linux" "aarch64-linux" "aarch64-darwin"] (
      system:
        if deploy-rs.lib ? ${system}
        then deploy-rs.lib.${system}.deployChecks (mkDeploy (lib.filterAttrs (_: n: n.system == system) deployableNodes))
        else {}
    );
  };
}
