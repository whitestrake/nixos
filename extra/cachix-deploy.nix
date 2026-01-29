{
  inputs,
  config,
  ...
}: {
  imports = [
    inputs.cachix-deploy.nixosModules.default
    ../secrets
  ];

  sops.secrets.cachixDeployEnv = {};
  services.cachix-deploy-agent.enable = true;
  systemd.services.cachix-deploy-agent.serviceConfig.EnvironmentFile = [
    config.sops.secrets.cachixDeployEnv.path
  ];
}
