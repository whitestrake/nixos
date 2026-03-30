{pkgs, ...}: let
  version = "2.11.2";

  src = pkgs.fetchFromGitHub {
    owner = "caddyserver";
    repo = "caddy";
    tag = "v${version}";
    hash = "sha256-QoGq8+lhaSQuC1VwIYE8h8N/ZC1ozfmIwmsIPk29Jos=";
  };

  caddyWithPlugins =
    (pkgs.caddy.overrideAttrs (oldAttrs: {
      inherit version src;
      vendorHash = "sha256-wjcmWKVmLBAybILUi8tKEDnFbhtybf042ODH7jEq6r8=";
    })).withPlugins {
      plugins = ["github.com/caddy-dns/cloudflare@v0.2.2"];
      hash = "sha256-Gb1nC5fZfj7IodQmKmEPGygIHNYhKWV1L0JJiqnVtbs=";
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
      mkdir -p $out
      ln -s ${caddyWithPlugins}/* $out/
    '';
  }
