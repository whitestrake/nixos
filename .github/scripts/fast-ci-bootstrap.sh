#!/usr/bin/env bash
# Temporary warm-store probe, matching the pinned quick installer's Nix version.
set -euo pipefail
umask 077

nix="$(readlink /nix/var/nix-quick-install-action/nix)"
test "$("$nix/bin/nix" --version)" = 'nix (Nix) 2.34.7'
"$nix/bin/nix-store" --query --requisites "$nix" | xargs "$nix/bin/nix-store" --check-validity

sudo mkdir -p /tmp/nix-builds
sudo chmod 1777 /tmp/nix-builds
config="${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf"
mkdir -p "$(dirname "$config")"
cat > "$config" <<'CONF'
experimental-features = nix-command flakes
accept-flake-config = true
nix-path = nixpkgs=flake:nixpkgs
build-dir = /tmp/nix-builds
connect-timeout = 10
download-attempts = 2
stalled-download-timeout = 60
max-jobs = auto
CONF
printf 'access-tokens = github.com=%s\n' "$GITHUB_TOKEN" >> "$config"
printf 'machine github.com\nlogin github-token\npassword %s\n' "$GITHUB_TOKEN" >> "$HOME/.netrc"
chmod 600 "$config" "$HOME/.netrc"
printf '%s/bin\n%s/.nix-profile/bin\n' "$nix" "$HOME" >> "$GITHUB_PATH"
{
  printf 'NIX_PROFILES=/nix/var/nix/profiles/default %s/.nix-profile\n' "$HOME"
  printf 'NIX_USER_PROFILE_DIR=/nix/var/nix/profiles/per-user/%s\n' "$USER"
  printf 'NIX_SSL_CERT_FILE=/etc/ssl/cert.pem\n'
} >> "$GITHUB_ENV"
