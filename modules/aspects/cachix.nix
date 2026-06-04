{den, ...}: {
  den.aspects.cachix-agent = {
    nixos = {config, ...}: {
      # Decrypt the shared agent token
      sops.secrets.cachixAgentToken = {};

      # Configure the Cachix agent service
      services.cachix-agent = {
        enable = true;
        credentialsFile = config.sops.secrets.cachixAgentToken.path;
      };

      # Trust and use the whitestrake Cachix cache for deployment activation
      nix.settings.substituters = ["https://whitestrake.cachix.org"];
      nix.settings.trusted-public-keys = [
        "whitestrake.cachix.org-1:UYcyluINGeeyAQgGOrEmOarylMNU5kLMagM0nXOkQK8="
      ];
    };
  };
}
