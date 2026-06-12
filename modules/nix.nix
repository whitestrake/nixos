{config, ...}: {
  den.default = {
    os.nix.settings = with builtins; {
      download-buffer-size = 524288000;
      trusted-users = ["root" "@wheel" "@staff"];
      experimental-features = ["nix-command" "flakes"];
      substituters = catAttrs "url" (attrValues config.caches);
      trusted-public-keys = catAttrs "key" (attrValues config.caches);
    };
  };
}
