{
  den,
  config,
  ...
}: {
  den.aspects.cachix-agent = {
    nixos = {config, ...}: {
      # Decrypt the shared agent token
      sops.secrets.cachixAgentToken = {};

      # Configure the Cachix agent service
      services.cachix-agent = {
        enable = true;
        credentialsFile = config.sops.secrets.cachixAgentToken.path;
      };
    };
  };
}
