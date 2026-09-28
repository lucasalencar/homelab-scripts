# coding-vm

Ubuntu Desktop 24.04 VM for coding.
System base only — languages, editors and Android SDK come from dotfiles.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the `code` VM (cloud image, cloud-init), provisions the guest and validates KVM. |
| `provision.sh` | Runs inside the guest (or via `install.sh` over SSH); `--check-only` runs validations. |
| `update.sh` | Upgrades guest packages via the guest agent. |

## Execution order

```
install.sh
update.sh   (run any time to upgrade)
```

## Examples

```bash
# On Proxmox as root, base install (no dotfiles hook)
./coding-vm/install.sh

# With your dotfiles bootstrap (local file on the host is copied into the guest)
DOTFILES_BOOTSTRAP="$HOME/dotfiles/bootstrap.sh" ./coding-vm/install.sh

# Custom sizing / storage / key
CODING_VM_CORES=6 CODING_VM_MEMORY_MB=8192 CODING_VM_DISK_GB=60 \
  CODING_VM_SSH_PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub" ./coding-vm/install.sh

# Validate an existing guest without reinstalling
./coding-vm/update.sh
```

`DOTFILES_BOOTSTRAP` is an executable script that `provision.sh` runs as the
cloud-init user after the system setup. If it is a file on the Proxmox host,
`install.sh` copies it to `/tmp/coding-vm-dotfiles-bootstrap` inside the VM;
otherwise the value is treated as a path that already exists in the guest.
When unset, the user environment step is skipped.

## Access (LAN only)

- SSH: `ssh <user>@code.marx.home` (also VS Code Remote-SSH)
- RDP: `code.marx.home:3389` (GNOME Remote Desktop, enable on first login if prompted)
- Fallback: Proxmox noVNC console

## Environment overrides

`CODING_VM_NAME`, `CODING_VM_CORES`, `CODING_VM_MEMORY_MB`,
`CODING_VM_DISK_GB`, `CODING_VM_STORAGE`, `CODING_VM_BRIDGE`,
`CODING_VM_SSH_PUBKEY_FILE`, `DOTFILES_BOOTSTRAP`.
