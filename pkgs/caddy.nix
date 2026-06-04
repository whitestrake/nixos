{pkgs, ...}: let
  version = "2.11.4";

  src = pkgs.fetchFromGitHub {
    owner = "caddyserver";
    repo = "caddy";
    tag = "v${version}";
    hash = "sha256-wzk8KRZfDCbbjRlBwkoKAoMjOhV4xF3yuXUueqtl1xM=";
  };

  vendorHash = "sha256-2GwSM7EKN9GwN6kte7CekpXIJ0vzHhhsnrs3TC6vTW4=";

  overriddenCaddy = pkgs.caddy.overrideAttrs (oldAttrs: {
    inherit version src vendorHash;
  });

  caddyWithPlugins =
    (pkgs.caddy.override {
      caddy = overriddenCaddy;
    }).withPlugins {
      plugins = ["github.com/caddy-dns/cloudflare@v0.2.2"];
      hash = "sha256-Rktd6YJX9JDC0t6ZsCSIGzOSXUwkFlaq/o8T61KR3Z4=";
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
