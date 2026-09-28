# coding-vm

Ubuntu Desktop 24.04 VM for coding.
System base only — languages, editors and Android SDK come from dotfiles.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Creates the `code` VM (cloud image, cloud-init), provisions the guest and validates KVM. |
| `provision.sh` | Runs inside the guest (or via `install.sh` over SSH); `--check-only` runs validations. |
| `ssh-setup.sh [user@]<vm_ip>` | **Run on your client machine.** Generates an SSH key, copies it to the VM and adds an ssh config entry. |
| `update.sh` | Upgrades guest packages via the guest agent. |

## Execution order

```
install.sh                                        (on Proxmox as root)
ssh-setup.sh [user@]<vm_ip>                       (on your Mac/client)
update.sh   (run any time to upgrade)
```

## SSH setup (from your Mac)

```bash
# Option A: pass the VM IP directly
./coding-vm/ssh-setup.sh 192.168.31.50

# Option B: config file
cp coding-vm/ssh_config.example ~/.coding_vm_config
# Edit ~/.coding_vm_config, then:
./coding-vm/ssh-setup.sh

# Afterwards (VS Code Remote-SSH works with the same alias)
ssh code
```

## Examples

```bash
# On Proxmox as root, base install (no dotfiles hook, no user key)
./coding-vm/install.sh

# Full flow with access from your Mac:
# 1. On the Mac, copy its public key to the Proxmox host
scp ~/.ssh/code.pub root@<proxmox-ip>:/root/code-mac.pub
# 2. On Proxmox as root, install with your Mac key + dotfiles hook
CODING_VM_SSH_PUBKEY_FILE=/root/code-mac.pub \
  DOTFILES_BOOTSTRAP="$HOME/dotfiles/bootstrap.sh" ./coding-vm/install.sh
# 3. Back on the Mac, write the ssh config entry
./coding-vm/ssh-setup.sh <vm-ip>
ssh code

# Custom sizing / storage / key
CODING_VM_CORES=6 CODING_VM_MEMORY_MB=8192 CODING_VM_DISK_GB=60 \
  CODING_VM_SSH_PUBKEY_FILE=/root/code-mac.pub ./coding-vm/install.sh

# Validate an existing guest without reinstalling
./coding-vm/update.sh
```

## SSH keys (two identities)

- **Host provisioning key** (`CODING_VM_PROVISION_KEY_FILE`, default
  `/root/.ssh/coding-vm-code`): generated on first run, used only by
  `install.sh` for `scp`/`ssh` provisioning. The Proxmox host needs no
  user access beyond this.
- **Your key** (`CODING_VM_SSH_PUBKEY_FILE`): your Mac's `~/.ssh/code.pub`
  copied to the host. Injected via cloud-init alongside the provisioning
  key, so login works immediately (Ubuntu cloud images lock password
  login, so adding the key later may require console access).

Without a user key the install still succeeds, but follow the `qm guest
exec` recovery hint it prints, or re-create the VM with the key set.

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
