{
  caches,
  den,
  ...
}: let
  sharedNixSettings = {
    experimental-features = ["nix-command" "flakes"];
  };
in {
  den.default = {
    nixos = {
      nix.settings =
        sharedNixSettings
        // {
          download-buffer-size = 524288000;
          substituters = [caches.garnix.url caches.nix-community.url];
          trusted-public-keys = [caches.garnix.key caches.nix-community.key];
          trusted-users = ["root" "@wheel" "@staff" "whitestrake"];
        };
    };

    darwin = {
      nix.settings =
        sharedNixSettings
        // {
          trusted-users = ["root" "@admin" "@staff" "whitestrake"];
        };

      environment.etc."nix/nix.custom.conf".text = let
        substituters = map (c: c.url) (builtins.attrValues caches);
        keys = map (c: c.key) (builtins.attrValues caches);
      in ''
        trusted-users = root @admin @staff whitestrake
        extra-substituters = ${builtins.concatStringsSep " " substituters}
        extra-trusted-public-keys = ${builtins.concatStringsSep " " keys}
      '';
    };
  };
}
