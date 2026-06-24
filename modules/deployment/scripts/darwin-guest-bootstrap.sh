#!/usr/bin/env bash
# Guest-side bootstrap for a fresh Namespace macOS builder.
set -euo pipefail

broker_public_key_b64="${1:?broker public key argument is required}"

decode_base64() {
  if printf '%s' "$broker_public_key_b64" | base64 --decode >/dev/null 2>&1; then
    printf '%s' "$broker_public_key_b64" | base64 --decode
  else
    printf '%s' "$broker_public_key_b64" | base64 -D
  fi
}

broker_public_key="$(decode_base64)"
if [ -z "$broker_public_key" ]; then
  echo "decoded broker public key is empty" >&2
  exit 1
fi

login_user="${SUDO_USER:-$(id -un)}"
if [ "$login_user" = "root" ] || [ -z "$login_user" ]; then
  login_user="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
fi
if [ -z "$login_user" ] || [ "$login_user" = "root" ]; then
  echo "could not determine Namespace login user for authorized_keys install" >&2
  exit 1
fi

user_home="$(
  dscl . -read "/Users/$login_user" NFSHomeDirectory 2>/dev/null \
    | awk '{print $2}' \
    | head -n 1
)"
if [ -z "$user_home" ]; then
  user_home="/Users/$login_user"
fi

install_authorized_key() {
  local ssh_dir="$1"
  local owner="$2"
  local auth_file="$ssh_dir/authorized_keys"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$auth_file"
  if ! grep -qxF "$broker_public_key" "$auth_file"; then
    printf '%s\n' "$broker_public_key" >> "$auth_file"
  fi
  chmod 600 "$auth_file"
  chown -R "$owner" "$ssh_dir" 2>/dev/null || true
}

install_authorized_key "$user_home/.ssh" "$login_user"
install_authorized_key "/var/root/.ssh" "root"

/usr/bin/ssh-keygen -A
dscl . -create /Users/root UserShell /bin/zsh >/dev/null 2>&1 || true

if ! lsof -i tcp:2222 -sTCP:LISTEN -t >/dev/null 2>&1; then
  /usr/sbin/sshd \
    -p 2222 \
    -o ListenAddress=127.0.0.1 \
    -o PermitRootLogin=yes
fi

if ! command -v nix >/dev/null 2>&1 && [ ! -x /nix/var/nix/profiles/default/bin/nix ]; then
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix \
    | sh -s -- install --no-confirm
fi

mkdir -p /usr/local/bin
for nix_bin in /nix/var/nix/profiles/default/bin/nix*; do
  [ -e "$nix_bin" ] || continue
  ln -sf "$nix_bin" "/usr/local/bin/$(basename "$nix_bin")"
done

if command -v nix >/dev/null 2>&1; then
  nix_version="$(nix --version)"
elif [ -x /nix/var/nix/profiles/default/bin/nix ]; then
  nix_version="$(/nix/var/nix/profiles/default/bin/nix --version)"
else
  echo "nix is not available after bootstrap" >&2
  exit 1
fi

if command -v nix-daemon >/dev/null 2>&1; then
  nix_daemon="$(command -v nix-daemon)"
elif [ -x /nix/var/nix/profiles/default/bin/nix-daemon ]; then
  nix_daemon="/nix/var/nix/profiles/default/bin/nix-daemon"
else
  echo "nix-daemon is not available after bootstrap" >&2
  exit 1
fi

if ! nix_daemon_version="$("$nix_daemon" --version 2>&1)"; then
  echo "nix-daemon --stdio command path is not runnable by root: $nix_daemon" >&2
  echo "$nix_daemon_version" >&2
  exit 1
fi

if ! nc -z localhost 2222; then
  echo "custom sshd on 127.0.0.1:2222 is not reachable" >&2
  exit 1
fi

echo "darwin-guest-bootstrap ok user=$login_user ${nix_version}"
