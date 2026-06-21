{pkgs, ...}: let
  version = "2.11.4";
  cloudflareDnsVersion = "0.2.4";

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
      plugins = ["github.com/caddy-dns/cloudflare@v${cloudflareDnsVersion}"];
      hash = "sha256-8yZDrejNKsaUnUaTUFYbarWNmxafqp2z2rWo+XRsxV8=";
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
          PATH="${
            pkgs.lib.makeBinPath [
              pkgs.coreutils
              pkgs.gitMinimal
              pkgs.nix
              pkgs.python3
            ]
          }:$PATH"

          repo_root=$(git rev-parse --show-toplevel)
          file_path="$repo_root/packages/caddy.nix"
          if [ ! -f "$file_path" ]; then
            echo "Error: expected caddy package at $file_path" >&2
            exit 1
          fi

          backup_path=$(mktemp)
          cp "$file_path" "$backup_path"
          restore_backup=1
          cleanup() {
            status=$?
            if [ "$restore_backup" -eq 1 ]; then
              if [ "$status" -ne 0 ]; then
                cp "$backup_path" "$file_path"
              fi
              rm -f "$backup_path"
            fi
          }
          trap cleanup EXIT

          python3 - "$repo_root" "$file_path" "$@" << 'EOF'
          import re
          import sys
          import urllib.request
          import json
          import subprocess

          repo_root = sys.argv[1]
          file_path = sys.argv[2]
          args = sys.argv[3:]

          if len(args) > 0:
              new_version = args[0]
          else:
              url = "https://api.github.com/repos/caddyserver/caddy/releases/latest"
              req = urllib.request.Request(url, headers={'User-Agent': 'nix-update'})
              with urllib.request.urlopen(req) as response:
                  data = json.loads(response.read().decode())
                  new_version = data['tag_name'].lstrip('v')

          print(f"Updating Caddy to version {new_version}...")

          def read_file():
              with open(file_path, 'r') as f:
                  return f.read()

          def write_file(content):
              with open(file_path, 'w') as f:
                  f.write(content)

          def replace_once(content, pattern, replacement, description):
              content, count = re.subn(pattern, replacement, content, count=1, flags=re.MULTILINE)
              if count != 1:
                  print(f"Error: Expected exactly one {description} match, found {count}")
                  sys.exit(1)
              return content

          content = read_file()
          content = replace_once(content, r'^  version = "[^"]*";', f'  version = "{new_version}";', "version")
          write_file(content)

          print("Fetching latest caddy-dns/cloudflare plugin version...")
          url_plugin = "https://api.github.com/repos/caddy-dns/cloudflare/tags"
          req_plugin = urllib.request.Request(url_plugin, headers={'User-Agent': 'nix-update'})
          with urllib.request.urlopen(req_plugin) as response:
              tags = json.loads(response.read().decode())

          semver_tag = re.compile(r'^v([0-9]+)\.([0-9]+)\.([0-9]+)$')
          plugin_versions = []
          for tag in tags:
              match = semver_tag.match(tag['name'])
              if match:
                  plugin_versions.append((tuple(int(part) for part in match.groups()), tag['name']))

          if not plugin_versions:
              print("Error: No vX.Y.Z tags found for caddy-dns/cloudflare")
              sys.exit(1)

          new_plugin_version = max(plugin_versions)[1].lstrip('v')

          print(f"Updating caddy-dns/cloudflare to version {new_plugin_version}...")
          content = read_file()
          content = replace_once(content, r'^  cloudflareDnsVersion = "[^"]*";', f'  cloudflareDnsVersion = "{new_plugin_version}";', "cloudflareDnsVersion")
          write_file(content)

          def update_hash(pattern, target_attr):
              content = read_file()
              # Replace the hash with fakeHash
              content = replace_once(
                  content,
                  pattern,
                  r'\g<1>sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\g<2>',
                  f"{target_attr} hash",
              )
              write_file(content)

              print(f"Running nix build .#{target_attr} to get hash...")
              proc = subprocess.run(
                  ["nix", "build", f"{repo_root}#{target_attr}", "--no-link", "--accept-flake-config"],
                  stdout=subprocess.DEVNULL,
                  stderr=subprocess.PIPE,
                  text=True,
              )

              match = re.search(r'got:\s+(sha256-[A-Za-z0-9+/=]+)', proc.stderr)
              if not match:
                  print(f"Error: Failed to extract hash for {target_attr} from build output:")
                  print(proc.stderr)
                  sys.exit(1)

              correct_hash = match.group(1)
              print(f"Found hash for {target_attr}: {correct_hash}")

              content = read_file()
              content = replace_once(
                  content,
                  pattern,
                  rf'\g<1>{correct_hash}\g<2>',
                  f"{target_attr} hash replacement",
              )
              write_file(content)

          # 1. Update source hash
          update_hash(r'(src\s*=\s*pkgs\.fetchFrom' + r'GitHub\s*\{\s*owner\s*=\s*\"caddyserver\";\s*repo\s*=\s*\"caddy\";[\s\S]*?hash\s*=\s*\")[^\"]*(\";)', "caddy")

          # 2. Update vendorHash
          update_hash(r'(^  vendor' + r'Hash\s*=\s*\")[^\"]*(\";)', "caddy.goModules")

          # 3. Update plugin hash
          update_hash(r'(plugins\s*=\s*\[\"github\.com/caddy-dns/cloudflare@v\$\{cloudflareDnsVersion\}\"\];\s*ha' + r'sh\s*=\s*\")[^\"]*(\";)', "caddy")
          EOF

          restore_backup=0
          rm -f "$backup_path"
          trap - EXIT
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
