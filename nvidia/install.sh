#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh" || { echo "Error: failed to load nvidia/lib.sh" >&2; exit 1; }

require_root

log_step "Starting NVIDIA driver installation (stage 1: pre-reboot)..."

nvidia_require_proxmox || exit 1

if ! nvidia_detect_gpu; then
    log_error "No NVIDIA GPU found via lspci. Check the card is seated and visible in the BIOS."
    exit 1
fi
log_info "NVIDIA GPU detected."

if nvidia_smi_ok; then
    log_success "NVIDIA driver already working (nvidia-smi answers)."
    log_info "Next: bash nvidia/configure.sh (post-reboot verification and sharing)."
    exit 0
fi

if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
    log_warning "SecureBoot is enabled: the NVIDIA module needs MOK signing (out of scope, see nvidia/README.md)."
fi

nvidia_ensure_non_free || exit 1

log_step "Refreshing APT and installing the driver stack..."
apt-get update
# shellcheck disable=SC2046  # word-splitting the package list is intended
apt-get install -y $(nvidia_driver_packages)

conf=$(nvidia_modprobe_conf)
log_step "Blacklisting nouveau ($conf)..."
mkdir -p "$(dirname "$conf")"
printf 'blacklist nouveau\noptions nouveau modeset=0\n' > "$conf"

log_step "Rebuilding initramfs..."
update-initramfs -u

log_success "Stage 1 complete. Reboot the host, then run:"
log_info "  bash nvidia/configure.sh"
