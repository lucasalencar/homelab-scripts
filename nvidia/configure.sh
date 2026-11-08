#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh" || { echo "Error: failed to load nvidia/lib.sh" >&2; exit 1; }

require_root

log_step "Verifying NVIDIA driver (stage 2: post-reboot)..."

nvidia_require_proxmox || exit 1

if ! nvidia_detect_gpu; then
    log_error "No NVIDIA GPU found via lspci. Check the card is seated and visible in the BIOS."
    exit 1
fi

if ! nvidia_driver_in_use; then
    log_error "Kernel is not using the nvidia driver (still nouveau or unbound)."
    log_error "Re-run bash nvidia/install.sh, reboot, then re-run this script."
    exit 1
fi

if ! nvidia_smi_ok; then
    log_error "nvidia-smi does not answer. Re-run bash nvidia/install.sh, reboot, then re-run this script."
    exit 1
fi

log_success "nvidia-smi answers: $(nvidia-smi -L 2>/dev/null | head -1)"

nodes=$(nvidia_dev_nodes) || {
    log_error "Driver answers but no $(nvidia_dev_dir)/nvidia* nodes exist."
    exit 1
}
log_info "Device nodes:"
echo "$nodes" | while IFS= read -r node; do log_info "  $node"; done

if systemctl enable --now nvidia-persistenced >/dev/null 2>&1; then
    log_info "nvidia-persistenced enabled."
else
    log_warning "nvidia-persistenced not available; device nodes still work without it."
fi

log_success "Driver healthy. Sharing model:"
log_info "  LXC: pass nodes per container (pct set <ctid> -dev0 /dev/nvidia0,...)."
log_info "  VMs: no PCIe passthrough (card stays shared); consume over the network."
log_info "  Jellyfin stays on Intel iGPU; reserve this card for compute."
