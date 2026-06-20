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
      hash = "sha256-wHW0l15aLswe7gV9WioXo//abd0sJI82I7zIroRG3uU=";
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

          python3 - "$@" << 'EOF'
          import re
          import sys
          import urllib.request
          import json
          import subprocess

          if len(sys.argv) > 1:
              new_version = sys.argv[1]
          else:
              url = "https://api.github.com/repos/caddyserver/caddy/releases/latest"
              req = urllib.request.Request(url, headers={'User-Agent': 'nix-update'})
              with urllib.request.urlopen(req) as response:
                  data = json.loads(response.read().decode())
                  new_version = data['tag_name'].lstrip('v')

          print(f"Updating Caddy to version {new_version}...")
          file_path = "packages/caddy.nix"

          def read_file():
              with open(file_path, 'r') as f:
                  return f.read()

          def write_file(content):
              with open(file_path, 'w') as f:
                  f.write(content)

          content = read_file()
          content = re.sub(r'version = "[^"]*";', f'version = "{new_version}";', content)
          write_file(content)

          def update_hash(pattern, target_attr):
              content = read_file()
              # Replace the hash with fakeHash
              content = re.compile(pattern, re.MULTILINE).sub(r'\g<1>sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\g<2>', content)
              write_file(content)

              print(f"Running nix build .#{target_attr} to get hash...")
              proc = subprocess.run(["nix", "build", f".#{target_attr}"], stderr=subprocess.PIPE, text=True)

              match = re.search(r'got:\s+(sha256-[A-Za-z0-9+/=]+)', proc.stderr)
              if not match:
                  print(f"Error: Failed to extract hash for {target_attr} from build output:")
                  print(proc.stderr)
                  sys.exit(1)

              correct_hash = match.group(1)
              print(f"Found hash for {target_attr}: {correct_hash}")

              content = read_file()
              content = re.compile(pattern, re.MULTILINE).sub(rf'\g<1>{correct_hash}\g<2>', content)
              write_file(content)

          # 1. Update source hash
          update_hash(r'(fetchFromGitHub\s*\{[\s\S]*?hash\s*=\s*\")[^\"]*(\";)', "caddy")

          # 2. Update vendorHash
          update_hash(r'(vendorHash\s*=\s*\")[^\"]*(\";)', "caddy.goModules")

          # 3. Update plugin hash
          update_hash(r'(plugins\s*=\s*\[[^\]]*\];\s*hash\s*=\s*\")[^\"]*(\";)', "caddy")
          EOF
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
