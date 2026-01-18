{pkgs, ...}: let
  version = "2.10.2";

  src = pkgs.fetchFromGitHub {
    owner = "caddyserver";
    repo = "caddy";
    tag = "v${version}";
    hash = "sha256-KvikafRYPFZ0xCXqDdji1rxlkThEDEOHycK8GP5e8vk=";
  };

  caddyWithPlugins =
    (pkgs.caddy.overrideAttrs (oldAttrs: {
      inherit version src;
      vendorHash = "sha256-wjcmWKVmLBAybILUi8tKEDnFbhtybf042ODH7jEq6r8=";
    })).withPlugins {
      plugins = ["github.com/caddy-dns/cloudflare@v0.2.2"];
      hash = "sha256-dnhEjopeA0UiI+XVYHYpsjcEI6Y1Hacbi28hVKYQURg=";
    };
in
  # Wrap in a transparent derivation so 'position' points to this file for nix-update
  pkgs.stdenv.mkDerivation {
    pname = "caddy";
    inherit version src;

    dontUnpack = true;

    passthru = caddyWithPlugins.passthru or {};

    meta =
      (caddyWithPlugins.meta or {})
      // {
        mainProgram = "caddy";
      };

    buildCommand = ''
      cp -a ${caddyWithPlugins} $out
      chmod -R u+w $out
    '';
  }
