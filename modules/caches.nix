{lib, ...}: let
  caches = {
    garnix = {
      url = "https://cache.garnix.io?priority=50";
      key = "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=";
    };
    nix-community = {
      url = "https://nix-community.cachix.org?priority=60";
      key = "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=";
    };
    whitestrake = {
      url = "https://whitestrake.cachix.org?priority=10";
      key = "whitestrake.cachix.org-1:UYcyluINGeeyAQgGOrEmOarylMNU5kLMagM0nXOkQK8=";
    };
  };
in {
  options.caches = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        url = lib.mkOption {
          type = lib.types.str;
          description = "Binary cache substituter URL";
        };
        key = lib.mkOption {
          type = lib.types.str;
          description = "Trusted public key for the cache";
        };
      };
    });
    description = "Shared binary cache definitions (url + trusted public key)";
  };

  config = {
    caches = caches;
    _module.args.caches = caches;
  };
}
