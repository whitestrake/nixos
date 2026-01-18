{pkgs, ...}: let
  version = "2.10.2";
in
  (pkgs.caddy.overrideAttrs (oldAttrs: {
    inherit version;
    src = pkgs.fetchFromGitHub {
      owner = "caddyserver";
      repo = "caddy";
      tag = "v${version}";
      hash = "sha256-KvikafRYPFZ0xCXqDdji1rxlkThEDEOHycK8GP5e8vk=";
    };
    vendorHash = "sha256-wjcmWKVmLBAybILUi8tKEDnFbhtybf042ODH7jEq6r8=";
  }))
  .withPlugins {
    plugins = ["github.com/caddy-dns/cloudflare@v0.2.2"];
    hash = "sha256-dnhEjopeA0UiI+XVYHYpsjcEI6Y1Hacbi28hVKYQURg=";
  }
