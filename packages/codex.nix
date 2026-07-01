{pkgs, ...}: let
  version = "0.142.5";

  systemMap = {
    "aarch64-darwin" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-aarch64-apple-darwin.tar.gz";
      hash = "sha256-cVaxmWJzXJz7VVzde6voxA55dogfhxK3gRmSGdLjpwc=";
    };
    "x86_64-linux" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-x86_64-unknown-linux-musl.tar.gz";
      hash = "sha256-y5M+w8thv0tfyI7s9eYUmCn6phclNbbvCvsBVL60qrg=";
    };
    "aarch64-linux" = {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-aarch64-unknown-linux-musl.tar.gz";
      hash = "sha256-sYx1xJZFkY+uI766CrQcBfB5QWAVEKJFG6l/5RlXPDg=";
    };
  };

  system = pkgs.stdenv.hostPlatform.system;
  asset =
    systemMap.${system}
    or (throw "codex: unsupported system ${system}; add a release asset to systemMap");
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

    passthru.updateScript = pkgs.writeShellScript "update-codex" ''
      set -euo pipefail
      PATH="${
        pkgs.lib.makeBinPath [
          pkgs.coreutils
          pkgs.curl
          pkgs.gitMinimal
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

      python3 - "$file_path" "$new_version" "$sri_darwin_arm" "$sri_linux_intel" "$sri_linux_arm" <<'PY'
      import re
      import sys

      file_path, version, sri_darwin_arm, sri_linux_intel, sri_linux_arm = sys.argv[1:]

      with open(file_path, 'r') as f:
          content = f.read()

      replacements = [
          (r'(^  version\s*=\s*")[^"]*(";)', version),
          (r'("aarch64-' + r'darwin"\s*=\s*\{[\s\S]*?hash\s*=\s*")[^"]*(";)', sri_darwin_arm),
          (r'("x86_64-' + r'linux"\s*=\s*\{[\s\S]*?hash\s*=\s*")[^"]*(";)', sri_linux_intel),
          (r'("aarch64-' + r'linux"\s*=\s*\{[\s\S]*?hash\s*=\s*")[^"]*(";)', sri_linux_arm),
      ]

      for pattern, value in replacements:
          content, count = re.subn(pattern, rf'\g<1>{value}\g<2>', content, count=1, flags=re.MULTILINE)
          if count != 1:
              raise SystemExit(f"failed to update exactly one match for {pattern}")

      with open(file_path, 'w') as f:
          f.write(content)
      PY

      restore_backup=0
      rm -f "$backup_path"
      trap - EXIT
    '';
  }
