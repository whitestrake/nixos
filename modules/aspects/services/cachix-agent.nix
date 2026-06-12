{...}: {
  den.aspects.cachix-agent.nixos = {config, ...}: {
    sops.secrets.cachixAgentToken = {};
    services.cachix-agent = {
      enable = true;
      credentialsFile = config.sops.secrets.cachixAgentToken.path;
    };
  };
}
