# coding-vm

Ubuntu Desktop 24.04 VM for coding.
System base only — languages, editors and Android SDK are installed manually
after first login.

## Scripts

| Script | Where it runs | Description |
|---|---|---|
| `install.sh` | Proxmox host, as root | Creates the `code` VM, provisions the guest and validates KVM. |
| `provision.sh` | Inside the guest (called by `install.sh`) | System packages, KVM group, SSH/RDP. `--check-only` runs validations. |
| `ssh-setup.sh [user@]<vm_ip>` | Your Mac / client, as your user | SSH key, key copy to the VM, `Host code` config entry. |
| `update.sh` | Proxmox host, as root | Upgrades guest packages via the guest agent. |

## Step by step

### 0. Prerequisites

- Proxmox host `marx` with nested virtualization enabled and room on
  `local-lvm` (~80 GB by default).
- Your Mac (client) reachable to the Proxmox host over SSH.

### 1. Prepare your Mac key and copy it to the Proxmox host (on the Mac)

```bash
# Generate once (skip if ~/.ssh/code already exists)
ssh-keygen -t ed25519 -f ~/.ssh/code -N ""

# Copy the public key to the Proxmox host (your normal user, not root —
# root SSH login is disabled on the host)
scp ~/.ssh/code.pub <proxmox-user>@<proxmox-ip>:~/code-mac.pub
```

### 2. Create and provision the VM (on Proxmox, as root)

```bash
CODING_VM_SSH_PUBKEY_FILE=/home/<user>/code-mac.pub ./coding-vm/install.sh
```

The key is required (run with `sudo` from your normal user; always absolute
paths — under sudo bare `$HOME` is `/root`, not your home). The install
prints the VM IP at the end.

### 3. Set up SSH from your Mac (on the Mac, as your user)

```bash
# Pass the VM IP from step 2 directly...
./coding-vm/ssh-setup.sh 192.168.31.50

# ...or keep it in a config file
cp coding-vm/ssh_config.example ~/.coding_vm_config
# Edit ~/.coding_vm_config, then:
./coding-vm/ssh-setup.sh
```

This ensures the key is authorized on the VM and adds the `Host code`
entry used by `ssh` and VS Code Remote-SSH. (Key generation is skipped —
the key already exists from step 1.)

### 4. Connect and verify

```bash
ssh code
```

- VS Code: Remote-SSH > Connect to Host > `code`.
- RDP (GUI tests): `<vm-ip>:3389`, GNOME Remote Desktop (LAN only).
- Fallback: Proxmox noVNC console.

After first login, set up your environment manually (languages, editors,
Android SDK): the system base (desktop, KVM, SSH) is already in place.
RDP (GNOME Remote Desktop) is enabled best-effort via `grdctl` during
provisioning — headless enable can fail with no GNOME session, in which
case enable it on first login: Settings > System > Remote Desktop.

### Ongoing: updates (on Proxmox, as root)

```bash
./coding-vm/update.sh
```

## Customization

```bash
CODING_VM_CORES=6 CODING_VM_MEMORY_MB=8192 CODING_VM_DISK_GB=60 \
  CODING_VM_SSH_PUBKEY_FILE=/home/<user>/code-mac.pub ./coding-vm/install.sh
```

All overrides: `CODING_VM_NAME`, `CODING_VM_CORES`, `CODING_VM_MEMORY_MB`,
`CODING_VM_BALLOON_MB`, `CODING_VM_DISK_GB`, `CODING_VM_STORAGE`,
`CODING_VM_BRIDGE`, `CODING_VM_CI_USER`, `CODING_VM_SSH_PUBKEY_FILE`,
`CODING_VM_PROVISION_KEY_FILE`, `CODING_VM_IMAGE_URL`, `CODING_VM_IMAGE_DIR`,
`CODING_VM_WAIT_TIMEOUT`, `CODING_VM_MIN_IMAGE_BYTES`, `CODING_VM_SSH_ALIAS`.

Custom `CODING_VM_IMAGE_URL` must keep the Ubuntu-cloud layout (a sibling
`SHA256SUMS` file in the same directory with a matching entry), or set
`CODING_VM_SKIP_CHECKSUM=1`.

## SSH keys (two identities)

- **Host provisioning key** (`CODING_VM_PROVISION_KEY_FILE`, default
  `/root/.ssh/coding-vm-code`): generated on first run, used only by
  `install.sh` for `scp`/`ssh` provisioning. The Proxmox host needs no
  user access beyond this.
- **Your key** (`CODING_VM_SSH_PUBKEY_FILE`, required): your Mac's
  `~/.ssh/code.pub` copied to the host. Injected via cloud-init alongside
  the provisioning key, so login works immediately (Ubuntu cloud images
  lock password login, so there is no later fallback).
