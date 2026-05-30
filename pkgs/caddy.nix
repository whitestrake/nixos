{pkgs, ...}: let
  version = "2.11.3";

  src = pkgs.fetchFromGitHub {
    owner = "caddyserver";
    repo = "caddy";
    tag = "v${version}";
    hash = "sha256-7Hgmo7ldDtbwl/acEY/4RNhSGnK/NNcXn+eIm1I8HKg=";
  };

  vendorHash = "sha256-QiZZxYsYFUneZ52TfFKQWJ42lmBofvUTZrHmDBuN2O4=";

  overriddenCaddy = pkgs.caddy.overrideAttrs (oldAttrs: {
    inherit version src vendorHash;
  });

  caddyWithPlugins =
    (pkgs.caddy.override {
      caddy = overriddenCaddy;
    }).withPlugins {
      plugins = ["github.com/caddy-dns/cloudflare@v0.2.2"];
      hash = "sha256-BJ4TKGHBddLVHw367Y49IMLCZItb02MlLdfNIMCbjp0=";
    };
in
  # Wrap in a transparent derivation so 'position' points to this file for nix-update
  pkgs.stdenv.mkDerivation {
    pname = "caddy";
    inherit version src;

    # Expose goModules to nix-update so it can find and update vendorHash
    goModules = overriddenCaddy.goModules;

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
