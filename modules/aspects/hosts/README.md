# Bootstrapping NixOS Hosts

This directory contains host-specific Den aspects. New NixOS hosts are normally introduced by staging an SSH host key locally, adding its derived `age` recipient to SOPS, installing with `nixos-anywhere`, then moving the host onto the normal rebuild/deploy path.

The files in this directory provide new-host templates and shared one-disk ZFS layouts:

- `_newhost.bios.example.nix` -> SeaBIOS / legacy BIOS VM template
- `_newhost.uefi.example.nix` -> OVMF / UEFI VM template
- `_disko.bios.default.nix` -> GRUB-compatible GPT/ZFS layout
- `_disko.uefi.default.nix` -> ESP + systemd-boot GPT/ZFS layout

Private host keys must never be committed.

## 1. Set Variables

Run from the repo root.

```sh
host=zeus
boot_mode=bios # bios for SeaBIOS, uefi for OVMF
disk=/dev/vda
target=root@nixos.lab.whitestrake.net
target_host="${target#*@}"
ssh_host="$host"
stage="/tmp/nixos-anywhere-$host"
anchor="server_$(printf '%s' "$host" | tr - _)"
```

`target` must be an SSH login that can install the machine. Confirm the destructive disk target before continuing.

Choose `boot_mode=bios` when the Proxmox VM firmware is SeaBIOS. Choose `boot_mode=uefi` when the VM firmware is OVMF/UEFI. For UEFI, configure the VM with OVMF, a persistent EFI disk/variables, and Secure Boot disabled unless a signed-boot flow is added. Do not switch this after install without planning to repartition or reinstall the VM.

`disk` must match the disk path passed to the disko template. `ssh_host` is the post-install SSH alias or FQDN used after the machine has booted into the installed system.

## 2. Create Host Files

```sh
git switch -c "feat/$host"
mkdir -p "modules/aspects/hosts/$host"
cp "modules/aspects/hosts/_newhost.$boot_mode.example.nix" "modules/aspects/hosts/$host/$host.nix"
```

Add the host to `modules/hosts.nix` under the correct system architecture, for example:

```nix
x86_64-linux = {
  zeus.users.whitestrake = {};
};
```

Edit `modules/aspects/hosts/<host>/<host>.nix`:

- choose the right included aspects
- set the disk path passed to the selected disko default to match `$disk`
- set `system.stateVersion`
- replace the throwing `networking.hostId`
- remove `services.qemuGuest.enable = true` if this is not a QEMU/Proxmox guest

Generate a ZFS host ID with:

```sh
nix run nixpkgs#openssl -- rand -hex 4
```

The shared defaults use the same root pool and dataset baseline:

- one ZFS root pool named from `config.networking.hostName`
- legacy-mounted datasets for `/`, `/var/log`, `/var/lib`, `/nix`, `/tmp`, `/home`, and `/opt/docker`
- `recordsize = "16K"` for the Docker dataset

The boot-mode-specific pieces are:

- BIOS / SeaBIOS: `_disko.bios.default.nix` creates a 1 MiB `EF02` BIOS boot partition and sets ZFS `compatibility = "grub2"` for GRUB. The disk path controls both disko formatting and GRUB installation; disko wires the GRUB device from the `EF02` partition.
- UEFI / OVMF: `_disko.uefi.default.nix` creates a 1 GiB ESP mounted at `/boot`; systemd-boot reads kernels from the ESP, so the root pool does not need GRUB compatibility.

If the host needs a different layout, copy the selected default into the host directory and change the import in `<host>.nix`:

```sh
cp "modules/aspects/hosts/_disko.$boot_mode.default.nix" "modules/aspects/hosts/$host/_disko.nix"
```

Then replace:

```nix
(import ../_disko.<boot_mode>.default.nix { ... })
```

with:

```nix
(import ./_disko.nix { ... })
```

Common reasons to customize are multiple disks, a separate storage pool, a cloud-provider image layout, non-ZFS storage, or a boot mode that does not match either default.

Do not create `_hardware.nix` by hand for a fresh host. The template imports it, but `nixos-anywhere --generate-hardware-config` writes the real file before building the install system.

## 3. Stage The Host SSH Key

`nixos-anywhere --extra-files` copies this directory into the target root. The path below becomes `/etc/ssh/ssh_host_ed25519_key` on the installed host.

```sh
install -d -m755 "$stage/etc/ssh"
ssh-keygen -t ed25519 -N "" -f "$stage/etc/ssh/ssh_host_ed25519_key"
```

Keep `$stage` outside the repo.

## 4. Add The SOPS Recipient

Use the public host key. `.sops.yaml` wants the `age1...` recipient, not an age identity.

```sh
recipient="$(nix run nixpkgs#ssh-to-age -- -i "$stage/etc/ssh/ssh_host_ed25519_key.pub")"

ANCHOR="$anchor" RECIPIENT="$recipient" nix run nixpkgs#yq-go -- -i '
  .keys += [strenv(RECIPIENT)] |
  .keys[-1] anchor = strenv(ANCHOR) |
  (.creation_rules[] | select(.path_regex == "modules/secrets/secrets\\.yaml$").key_groups[0].age) += [strenv(ANCHOR)] |
  (.creation_rules[] | select(.path_regex == "modules/secrets/secrets\\.yaml$").key_groups[0].age[-1]) alias = strenv(ANCHOR)
' .sops.yaml

sops updatekeys -y modules/secrets/secrets.yaml
grep -q "&$anchor" .sops.yaml
sops -d modules/secrets/secrets.yaml >/dev/null
```

This works because `modules/secrets/sops.nix` configures sops-nix to read `/etc/ssh/ssh_host_ed25519_key`.

## 5. Verify Before Install

For a fresh host, `_hardware.nix` does not exist yet. Keep pre-install checks to formatting and syntax checks that do not evaluate `nixosConfigurations.$host`:

```sh
nix fmt
disko_file="modules/aspects/hosts/$host/_disko.nix"
test -e "$disko_file" || disko_file="modules/aspects/hosts/_disko.$boot_mode.default.nix"
nix-instantiate --parse "modules/aspects/hosts/$host/$host.nix" >/dev/null
nix-instantiate --parse "$disko_file" >/dev/null
```

Do not run `nix flake check` or build `nixosConfigurations.$host` until `_hardware.nix` exists, unless you are reusing an existing hardware config.

## 6. Install With nixos-anywhere

This will repartition the configured disk. Confirm the target disk immediately before running it:

```sh
ssh "$target" "lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS $disk"
```

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake "path:$PWD#$host" \
  --generate-hardware-config nixos-generate-config "modules/aspects/hosts/$host/_hardware.nix" \
  --target-host "$target" \
  --extra-files "$stage"
```

This writes `modules/aspects/hosts/$host/_hardware.nix` locally. If the generated hardware file already exists and is correct, omit `--generate-hardware-config`.

## 7. Verify First Boot

After reboot, clear stale known-host entries and verify SSH. `ssh_host` must resolve to the installed system.

```sh
ssh-keygen -R "$target_host"
ssh-keygen -R "$ssh_host"
ssh "$ssh_host" true
ssh "$ssh_host" 'hostname; test -r /etc/ssh/ssh_host_ed25519_key.pub'
```

Check that SOPS secrets materialized:

```sh
ssh "$ssh_host" 'systemctl --failed --no-pager'
ssh "$ssh_host" 'sudo systemctl status sops-nix --no-pager || true'
ssh "$ssh_host" 'sudo test -e /run/secrets && sudo find /run/secrets -maxdepth 2 -type f | sed -n "1,20p"'
```

## 8. Move Onto The Normal Switch Path

From the repo root:

```sh
ssh -A -t "$ssh_host" 'sudo true'
ssh -A "$ssh_host" 'sudo -n true'

NIX_SSHOPTS="-A" nixos-rebuild --fast \
  --flake "path:$PWD#$host" \
  --build-host "$ssh_host" \
  --target-host "$ssh_host" \
  --use-remote-sudo \
  switch
```

If `sudo -n true` fails, prime sudo again and do not rerun the switch until the non-interactive sudo check passes.

## 9. Clean Up And Commit

Remove the local staging directory only after confirming the host key was installed and SSH works.

```sh
rm -rf "$stage"
nix fmt
nix flake check --no-build "path:$PWD"
nix build "path:$PWD#nixosConfigurations.$host.config.system.build.toplevel" --dry-run
git status --short
```

Commit:

- `modules/hosts.nix`
- `modules/aspects/hosts/$host/$host.nix`
- `modules/aspects/hosts/$host/_hardware.nix`
- `modules/aspects/hosts/$host/_disko.nix`, if a host-local disko file was created
- `.sops.yaml`
- `modules/secrets/secrets.yaml`

Do not commit staged private keys.
