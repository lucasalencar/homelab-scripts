# coding-vm

Ubuntu Desktop 24.04 VM for coding.
System base only — languages, editors and Android SDK come from dotfiles.

## Scripts

| Script | Where it runs | Description |
|---|---|---|
| `install.sh` | Proxmox host, as root | Creates the `code` VM, provisions the guest and validates KVM. |
| `provision.sh` | Inside the guest (called by `install.sh`) | System packages, KVM group, SSH/RDP, dotfiles hook. `--check-only` runs validations. |
| `ssh-setup.sh [user@]<vm_ip>` | Your Mac / client, as your user | SSH key, key copy to the VM, `Host code` config entry. |
| `update.sh` | Proxmox host, as root | Upgrades guest packages via the guest agent. |

## Step by step

### 0. Prerequisites

- Proxmox host `marx` with nested virtualization enabled and room on
  `local-lvm` (~80 GB by default).
- On your Mac: an SSH key for the VM (`~/.ssh/code`, see step 2 if you
  don't have one yet).

### 1. Copy your Mac public key to the Proxmox host (on the Mac)

```bash
scp ~/.ssh/code.pub root@<proxmox-ip>:/root/code-mac.pub
```

Skip only if you plan to add access later (see step 4).

### 2. Create and provision the VM (on Proxmox, as root)

```bash
CODING_VM_SSH_PUBKEY_FILE=/root/code-mac.pub \
  DOTFILES_BOOTSTRAP="$HOME/dotfiles/bootstrap.sh" ./coding-vm/install.sh
```

The install prints the VM IP at the end. `DOTFILES_BOOTSTRAP` is optional:
a host-side script copied into the guest and run as your user (see below).
Without `CODING_VM_SSH_PUBKEY_FILE` the install still succeeds, but your
key is not injected — follow the recovery hint it prints.

### 3. Set up SSH from your Mac (on the Mac, as your user)

```bash
# Pass the VM IP from step 2 directly...
./coding-vm/ssh-setup.sh 192.168.31.50

# ...or keep it in a config file
cp coding-vm/ssh_config.example ~/.coding_vm_config
# Edit ~/.coding_vm_config, then:
./coding-vm/ssh-setup.sh
```

This generates `~/.ssh/code` if missing, ensures the key is authorized on
the VM, and adds the `Host code` entry used by `ssh` and VS Code
Remote-SSH.

### 4. Connect and verify

```bash
ssh code
```

- VS Code: Remote-SSH > Connect to Host > `code`.
- RDP (GUI tests): `<vm-ip>:3389`, GNOME Remote Desktop (LAN only).
- Fallback: Proxmox noVNC console.
- No user key injected in step 2? Add it from the host with:
  `qm guest exec <id> -- bash -c "echo 'PUBKEY' >> /home/<user>/.ssh/authorized_keys"`.

### Ongoing: updates (on Proxmox, as root)

```bash
./coding-vm/update.sh
```

## Customization

```bash
CODING_VM_CORES=6 CODING_VM_MEMORY_MB=8192 CODING_VM_DISK_GB=60 \
  CODING_VM_SSH_PUBKEY_FILE=/root/code-mac.pub ./coding-vm/install.sh
```

All overrides: `CODING_VM_NAME`, `CODING_VM_CORES`, `CODING_VM_MEMORY_MB`,
`CODING_VM_BALLOON_MB`, `CODING_VM_DISK_GB`, `CODING_VM_STORAGE`,
`CODING_VM_BRIDGE`, `CODING_VM_CI_USER`, `CODING_VM_SSH_PUBKEY_FILE`,
`CODING_VM_PROVISION_KEY_FILE`, `CODING_VM_IMAGE_URL`, `CODING_VM_IMAGE_DIR`,
`CODING_VM_WAIT_TIMEOUT`, `DOTFILES_BOOTSTRAP`, `CODING_VM_SSH_ALIAS`.

## SSH keys (two identities)

- **Host provisioning key** (`CODING_VM_PROVISION_KEY_FILE`, default
  `/root/.ssh/coding-vm-code`): generated on first run, used only by
  `install.sh` for `scp`/`ssh` provisioning. The Proxmox host needs no
  user access beyond this.
- **Your key** (`CODING_VM_SSH_PUBKEY_FILE`): your Mac's `~/.ssh/code.pub`
  copied to the host. Injected via cloud-init alongside the provisioning
  key, so login works immediately (Ubuntu cloud images lock password
  login, so adding the key later may require console access).

`DOTFILES_BOOTSTRAP` is an executable script that `provision.sh` runs as the
cloud-init user after the system setup. If it is a file on the Proxmox host,
`install.sh` copies it to `/tmp/coding-vm-dotfiles-bootstrap` inside the VM;
otherwise the value is treated as a path that already exists in the guest.
When unset, the user environment step is skipped.
