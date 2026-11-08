# NVIDIA host driver

Proprietary driver for the host RTX 4060 Ti so the card is shared by many
consumers. No PCIe passthrough: LXCs get device nodes, VMs consume over
the network.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Stage 1 (pre-reboot): enables `non-free`, installs headers + driver, blacklists nouveau, rebuilds initramfs. |
| `configure.sh` | Stage 2 (post-reboot): verifies `nvidia-smi`, device nodes, and persistence. |
| `update.sh` | Re-installs headers + driver after kernel upgrades and re-verifies. |
| `lib.sh` | Shared detection/converge helpers (sourced by the scripts above, not run directly). |

## Execution order

```
bash nvidia/install.sh     # then reboot the host
bash nvidia/configure.sh   # verify the driver is healthy
bash nvidia/update.sh      # run any time to upgrade (reboot if prompted)
```

See `nvidia/install.sh` for what each step does.

## Environment

| Variable | Default | Description |
|---|---|---|
| `NVIDIA_DEBIAN_SOURCES` | `/etc/apt/sources.list.d/debian.sources` | deb822 file gaining the `non-free` component. |
| `NVIDIA_MODPROBE_CONF` | `/etc/modprobe.d/blacklist-nouveau-nvidia.conf` | Nouveau blacklist written by `install.sh`. |
| `NVIDIA_DEV_DIR` | `/dev` | Directory scanned for `nvidia*` device nodes. |
| `NVIDIA_PVE_DIR` | `/etc/pve` | Proxmox host marker checked before any change. |
| `NVIDIA_UNAME_R` | `$(uname -r)` | Kernel release selecting the `proxmox-headers-*` package. |

## Sharing model

- LXC: share via device passthrough, e.g. `pct set <ctid> -dev0 /dev/nvidia0,/dev/nvidiactl,...` — many containers at once.
- VM: no device passthrough on this card (it would pin the GPU to one VM); expose services over the LAN instead.
- Jellyfin stays on the Intel iGPU (`/dev/dri`); this card is reserved for compute.
- SecureBoot is off on this host; if re-enabled, the module needs MOK signing before it loads.

## Ports & Caddy

None — host kernel driver, no web service, no Caddy route.

## Verification

```bash
nvidia-smi
ls /dev/nvidia*
lspci -nnk | grep -A2 NVIDIA
bash nvidia/configure.sh
```
