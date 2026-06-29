{config, ...}: {
  den.default = {
    nixos.nix.settings.trusted-users = ["@wheel"];

    darwin = {
      config,
      lib,
      ...
    }: {
      nix = {
        # Determinate Nix handles nix daemon on macOS.
        enable = false;
        settings.trusted-users = ["@staff"];
      };

      # Because we disable nix-darwin's management of the nix daemon, we must
      # manually inject our evaluated nix.settings into Determinate's custom config.
      environment.etc."nix/nix.custom.conf".text = with lib; ''
        extra-trusted-users = ${concatStringsSep " " config.nix.settings.trusted-users}
        extra-substituters = ${concatStringsSep " " config.nix.settings.substituters}
        extra-trusted-public-keys = ${concatStringsSep " " config.nix.settings.trusted-public-keys}
      '';
    };

    os.nix.settings = with builtins; {
      download-buffer-size = 524288000;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      substituters = catAttrs "url" (attrValues config.caches);
      trusted-public-keys = catAttrs "key" (attrValues config.caches);
    };
  };
}
