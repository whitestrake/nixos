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

    passthru =
      (caddyWithPlugins.passthru or {})
      // {
        updateScript = pkgs.writeShellScript "update-caddy" ''
          set -euo pipefail
          PATH="${pkgs.lib.makeBinPath [pkgs.nix pkgs.python3]}:$PATH"

          if [ "$#" -gt 0 ]; then
            nix run nixpkgs#nix-update -- --flake caddy --version "$1"
          else
            nix run nixpkgs#nix-update -- --flake caddy
          fi

          file_path="packages/caddy.nix"

          python3 -c "
          import re
          with open('$file_path', 'r') as f:
              content = f.read()

          pattern = re.compile(r'(plugins\s*=\s*\[[^\]]*\];\s*hash\s*=\s*\")[^\"]*(\";)', re.MULTILINE)
          new_content = pattern.sub(r'\g<1>sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\g<2>', content)

          with open('$file_path', 'w') as f:
              f.write(new_content)
          "

          echo "Building Caddy to compute plugin vendor hash..."
          build_log=$(nix build .#caddy 2>&1 || true)

          correct_hash=$(python3 -c "
          import re, sys
          build_log = \"\"\"$build_log\"\"\"
          match = re.search(r'got:\s+(sha256-[A-Za-z0-9+/=]+)', build_log)
          if match:
              print(match.group(1))
          else:
              sys.exit(1)
          " || {
            echo "Error: Failed to extract withPlugins hash from build output:"
            echo "$build_log"
            exit 1
          })

          echo "Extracted withPlugins hash: $correct_hash"

          python3 -c "
          import re
          with open('$file_path', 'r') as f:
              content = f.read()

          pattern = re.compile(r'(plugins\s*=\s*\[[^\]]*\];\s*hash\s*=\s*\")[^\"]*(\";)', re.MULTILINE)
          new_content = pattern.sub(rf'\g<1>$correct_hash\g<2>', content)

          with open('$file_path', 'w') as f:
              f.write(new_content)
          "
        '';
      };

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
