{lib, ...}: {
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
    caches = {
      cachix = {
        url = "https://whitestrake.cachix.org?priority=50";
        key = "whitestrake.cachix.org-1:UYcyluINGeeyAQgGOrEmOarylMNU5kLMagM0nXOkQK8=";
      };
    };
  };
}
