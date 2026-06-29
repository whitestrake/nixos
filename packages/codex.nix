{
  pkgs,
  unstablePkgs ? pkgs,
  ...
}: let
  version = "0.142.4";

  systemMap = {
    "aarch64-darwin" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-aarch64-apple-darwin.tar.gz";
      hash = "sha256-opLH0qJ/o3awrozvAWG2tz/kue1/K6pz2HYmL9swyB0=";
    };
    "x86_64-linux" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-x86_64-unknown-linux-musl.tar.gz";
      hash = "sha256-8KxDdRxtOympc6hgqN5SitecsgzBKWYRkwo9XJHd75U=";
    };
    "aarch64-linux" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-aarch64-unknown-linux-musl.tar.gz";
      hash = "sha256-pUbuBZFTE/6jQPgxW1T0PQd/Q5Cvu1ry3pRNSAE9RH8=";
    };
  };

  fallbackSrc = pkgs.fetchFromGitHub {
    owner = "openai";
    repo = "codex";
    tag = "rust-v${version}";
    hash = "sha256-cYkdLy0+KMjcx0k7IDACsiTK3ZZks6cmwbeDMheN6WY=";
  };

  fallbackCargoDeps = unstablePkgs.rustPlatform.fetchCargoVendor {
    src = fallbackSrc;
    sourceRoot = "${fallbackSrc.name}/codex-rs";
    name = "codex-${version}";
    hash = "sha256-1gDiCB3Nf/0aIm+EoL3g9C0xbCi3cv6TfH5VytjJpOY=";
  };

  system = pkgs.stdenv.hostPlatform.system;
in
  if systemMap ? ${system}
  then let
    asset = systemMap.${system};
  in
    pkgs.stdenv.mkDerivation {
      pname = "codex";
      inherit version;

      src = pkgs.fetchurl {
        inherit (asset) url hash;
      };

      sourceRoot = ".";

      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        if [ -f codex ]; then
          cp codex $out/bin/codex
        elif [ -f bin/codex ]; then
          cp bin/codex $out/bin/codex
        else
          binary=$(find . -maxdepth 1 -type f -name "codex-*" | head -n 1)
          if [ -n "$binary" ]; then
            cp "$binary" $out/bin/codex
          else
            echo "Error: Could not find codex binary in source"
            exit 1
          fi
        fi
        chmod +x $out/bin/codex
        runHook postInstall
      '';

      meta = {
        mainProgram = "codex";
      };

      passthru = {
        inherit fallbackCargoDeps;

        updateScript = pkgs.writeShellScript "update-codex" ''
          set -euo pipefail
          PATH="${
            pkgs.lib.makeBinPath [
              pkgs.coreutils
              pkgs.curl
              pkgs.gitMinimal
              pkgs.gnused
              pkgs.jq
              pkgs.nix
              pkgs.python3
            ]
          }:$PATH"

          if [ "$#" -gt 0 ]; then
            new_version="$1"
          else
            latest_tag=$(curl -fsSL https://api.github.com/repos/openai/codex/releases/latest | jq -r .tag_name)
            new_version=''${latest_tag#rust-v}
          fi

          echo "Updating codex to version $new_version..."
          repo_root=$(git rev-parse --show-toplevel)
          file_path="$repo_root/packages/codex.nix"
          if [ ! -f "$file_path" ]; then
            echo "Error: expected codex package at $file_path" >&2
            exit 1
          fi

          echo "Prefetching hash for aarch64-darwin..."
          hash_darwin_arm=$(nix-prefetch-url "https://github.com/openai/codex/releases/download/rust-v$new_version/codex-aarch64-apple-darwin.tar.gz" --type sha256)
          sri_darwin_arm=$(nix hash convert --hash-algo sha256 "$hash_darwin_arm")

          echo "Prefetching hash for x86_64-linux..."
          hash_linux_intel=$(nix-prefetch-url "https://github.com/openai/codex/releases/download/rust-v$new_version/codex-x86_64-unknown-linux-musl.tar.gz" --type sha256)
          sri_linux_intel=$(nix hash convert --hash-algo sha256 "$hash_linux_intel")

          echo "Prefetching hash for aarch64-linux..."
          hash_linux_arm=$(nix-prefetch-url "https://github.com/openai/codex/releases/download/rust-v$new_version/codex-aarch64-unknown-linux-musl.tar.gz" --type sha256)
          sri_linux_arm=$(nix hash convert --hash-algo sha256 "$hash_linux_arm")

          echo "Prefetching fallback source hash..."
          hash_source=$(nix-prefetch-url --unpack "https://github.com/openai/codex/archive/refs/tags/rust-v$new_version.tar.gz" --type sha256)
          sri_source=$(nix hash convert --hash-algo sha256 "$hash_source")

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

          echo "Setting fallback cargoDeps hash to fakeHash..."
          python3 - "$file_path" "$new_version" "$sri_darwin_arm" "$sri_linux_intel" "$sri_linux_arm" "$sri_source" <<'PY'
          import re
          import sys

          file_path, version, sri_darwin_arm, sri_linux_intel, sri_linux_arm, sri_source = sys.argv[1:]

          with open(file_path, 'r') as f:
              content = f.read()

          replacements = [
              (r'(^  version\s*=\s*")[^"]*(";)', version),
              (r'("aarch64-' + r'darwin"\s*=\s*\{[\s\S]*?hash\s*=\s*")[^"]*(";)', sri_darwin_arm),
              (r'("x86_64-' + r'linux"\s*=\s*\{[\s\S]*?hash\s*=\s*")[^"]*(";)', sri_linux_intel),
              (r'("aarch64-' + r'linux"\s*=\s*\{[\s\S]*?hash\s*=\s*")[^"]*(";)', sri_linux_arm),
              (r'(fallbackSrc\s*=\s*pkgs\.fetchFromGitHub\s*\{[\s\S]*?owner\s*=\s*"openai";[\s\S]*?repo\s*=\s*"codex";[\s\S]*?hash\s*=\s*")[^"]*(";)', sri_source),
          ]

          for pattern, value in replacements:
              content, count = re.subn(pattern, rf'\g<1>{value}\g<2>', content, count=1, flags=re.MULTILINE)
              if count != 1:
                  raise SystemExit(f"failed to update exactly one match for {pattern}")

          content, count = re.subn(
              r'(fallbackCargoDeps\s*=\s*unstablePkgs\.rustPlatform\.fetchCargoVendor\s*\{[\s\S]*?hash\s*=\s*)(?:"[^"]*"|pkgs\.lib\.fakeHash)(;)',
              r'\g<1>pkgs.lib.fakeHash\g<2>',
              content,
              count=1,
              flags=re.MULTILINE,
          )
          if count != 1:
              raise SystemExit("failed to set exactly one fallback cargoDeps hash to fakeHash")

          with open(file_path, 'w') as f:
              f.write(content)
          PY

          echo "Building .#codex.fallbackCargoDeps to get hash..."
          cargo_output=$(nix build "$repo_root#codex.fallbackCargoDeps" --no-link --accept-flake-config 2>&1 >/dev/null || true)
          sri_cargo=$(
            CARGO_OUTPUT="$cargo_output" python3 - <<'PY'
          import os
          import re
          import sys

          match = re.search(r"got:\s+(sha256-[A-Za-z0-9+/=]+)", os.environ["CARGO_OUTPUT"])
          if not match:
              print("Error: failed to extract fallback cargoDeps hash from nix output", file=sys.stderr)
              print(os.environ["CARGO_OUTPUT"], file=sys.stderr)
              sys.exit(1)

          print(match.group(1))
          PY
          )

          python3 - "$file_path" "$sri_cargo" <<'PY'
          import re
          import sys

          file_path, sri_cargo = sys.argv[1:]

          with open(file_path, 'r') as f:
              content = f.read()

          content, count = re.subn(
              r'(fallbackCargoDeps\s*=\s*unstablePkgs\.rustPlatform\.fetchCargoVendor\s*\{[\s\S]*?hash\s*=\s*)(?:"[^"]*"|pkgs\.lib\.fakeHash)(;)',
              rf'\g<1>"{sri_cargo}"\g<2>',
              content,
              count=1,
              flags=re.MULTILINE,
          )
          if count != 1:
              raise SystemExit("failed to restore exactly one fallback cargoDeps hash")

          with open(file_path, 'w') as f:
              f.write(content)
          PY

          restore_backup=0
          rm -f "$backup_path"
          trap - EXIT
        '';
      };
    }
  else
    unstablePkgs.codex.overrideAttrs (oldAttrs: {
      inherit version;
      src = fallbackSrc;
      cargoDeps = fallbackCargoDeps;

      postPatch = ''
        substituteInPlace $cargoDepsCopy/*/webrtc-sys-*/build.rs \
          --replace-fail "cargo:rustc-link-lib=static=webrtc" "cargo:rustc-link-lib=dylib=webrtc"
        substituteInPlace Cargo.toml \
          --replace-fail 'lto = "thin"' "" \
          --replace-fail 'codegen-units = 4' ""
      '';
    })
